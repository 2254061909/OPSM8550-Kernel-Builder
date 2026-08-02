#!/usr/bin/env bash
#
# susfs patching helpers and the end-to-end apply routine. Sourced, not
# executed. Depends on lib/kernel-helpers.sh.
#
# NOTE: compile-kernel.sh runs under `set -euo pipefail`. Several helpers here
# probe the tree with grep/find, where "no match" is a normal outcome that
# returns 1. Those functions disable errexit locally and restore it on exit,
# otherwise a routine miss aborts the whole build with no message at all.
#

apply_susfs_task_mmu_fix() {
  local file="fs/proc/task_mmu.c"

  if grep -q 'susfs_def.h' "$file"; then
    echo "[+] task_mmu.c already includes susfs_def.h."
    return 0
  fi

  if grep -q '^#include <linux/pkeys.h>$' "$file"; then
    sed -i '/^#include <linux\/pkeys.h>$/a #ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif' "$file"
    echo "[+] Applied fallback susfs include fix to task_mmu.c."
    return 0
  fi

  echo "[-] Could not find a stable insertion point in $file."
  return 1
}

patch_susfs_kernelsu_layout() {
  local file="fs/susfs.c"
  local driver_dir
  local target_include

  [[ -f "$file" ]] || return 0

  driver_dir="$(detect_kernelsu_driver_dir)" || return 0
  target_include="../${driver_dir}/kernelsu/hook/core_hook.h"

  if [[ -f "${driver_dir}/kernelsu/hook/core_hook.h" ]] && [[ ! -f "${driver_dir}/kernelsu/core_hook.h" ]]; then
    sed -i "s|\"\\.\\./drivers/kernelsu/core_hook.h\"|\"${target_include}\"|" "$file"
    echo "[+] Patched susfs core_hook include for nested KernelSU layout."
  fi
}

# Line number of the anchor we insert restored #includes after.
#
# It MUST be the FIRST #include in the file, not the last. Several KSU sources
# end with includes inside a conditional block, e.g. core/init.c:
#
#     #if defined(CONFIG_STACKPROTECTOR) && ... && defined(MODULE) ...
#     #include <linux/stackprotector.h>
#     #include <linux/random.h>          <-- last #include in the file
#     #endif
#
# For a built-in (non-module) build that block is preprocessed away, so
# anything appended after it is silently invisible to the compiler: the file
# grows by a line and the build fails with exactly the same errors.
_first_include_line() {
  grep -n '^#include' "$1" | head -n 1 | cut -d: -f1
}

_decl_symbol_name() {
  local line="$1"
  if [[ "$line" == *"("* ]]; then
    printf '%s' "$line" | sed -E 's/[[:space:]]*\(.*//' | grep -oE '[A-Za-z_][A-Za-z0-9_]*$'
  else
    printf '%s' "$line" | sed -E 's/[[:space:]]*;[[:space:]]*$//' | grep -oE '[A-Za-z_][A-Za-z0-9_]*$'
  fi
}

restore_includes_deleted_by_susfs_patch() {
  set +e
  local ksu_repo_dir="$1"
  local file line restored=0

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local abs="${ksu_repo_dir}/${file}"
    [[ -f "$abs" ]] || continue

    local to_restore=()
    while IFS= read -r line; do
      [[ "$line" =~ ^#include ]] || continue
      [[ "$line" == *susfs* ]] && continue
      grep -Fxq "$line" "$abs" && continue
      to_restore+=("$line")
    done < <(git -C "$ksu_repo_dir" diff -U0 -- "$file" \
               | grep '^-' | grep -v '^---' | sed 's/^-//')

    [[ "${#to_restore[@]}" -eq 0 ]] && continue

    local anchor
    anchor="$(_first_include_line "$abs")"
    if [[ -z "$anchor" ]]; then
      echo "[!] ${file}: no #include anchor found, skipping restore"
      continue
    fi

    echo "[+] Restoring ${#to_restore[@]} #include(s) in ${file} (after line ${anchor}):"
    printf '      %s\n' "${to_restore[@]}"

    local tmp="/tmp/ksu_inc.$$"
    printf '%s\n' "${to_restore[@]}" > "$tmp"
    sed -i "${anchor}r ${tmp}" "$abs"
    rm -f "$tmp"
    restored=1
  done < <(git -C "$ksu_repo_dir" diff --name-only -- '*.c' '*.h')

  [[ "$restored" -eq 0 ]] && echo "[i] No #include lines were removed by the patch."
  set -e
  return 0
}

restore_declarations_deleted_from_ksu_headers() {
  set +e
  local ksu_repo_dir="$1"
  local header line restored=0

  while IFS= read -r header; do
    [[ -z "$header" ]] && continue
    local abs="${ksu_repo_dir}/${header}"
    [[ -f "$abs" ]] || continue

    local to_restore=()
    while IFS= read -r line; do
      [[ "$line" =~ ^extern[[:space:]].*\;$ ]] || \
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_[:space:]\*]*\(.*\)\;$ ]] || continue
      [[ "$line" == *susfs* ]] && continue

      local sym
      sym="$(_decl_symbol_name "$line")"
      [[ -z "$sym" ]] && continue
      grep -qE "\b${sym}\b" "$abs" && continue

      to_restore+=("$line")
    done < <(git -C "$ksu_repo_dir" diff -U0 -- "$header" \
               | grep '^-' | grep -v '^---' | sed 's/^-//')

    [[ "${#to_restore[@]}" -eq 0 ]] && continue

    echo "[+] Restoring ${#to_restore[@]} declaration(s) in ${header}:"
    printf '      %s\n' "${to_restore[@]}"

    local guard_line tmp="/tmp/ksu_decl.$$"
    guard_line="$(grep -n '^#endif' "$abs" | tail -n 1 | cut -d: -f1)"
    {
      printf '\n/* Restored: removed by the susfs KernelSU patch, still used upstream. */\n'
      printf '%s\n' "${to_restore[@]}"
    } > "$tmp"

    if [[ -n "$guard_line" ]] && [[ "$guard_line" -gt 1 ]]; then
      sed -i "$((guard_line - 1))r ${tmp}" "$abs"
    else
      cat "$tmp" >> "$abs"
    fi
    rm -f "$tmp"
    restored=1
  done < <(git -C "$ksu_repo_dir" diff --name-only -- '*.h')

  [[ "$restored" -eq 0 ]] && echo "[i] No declarations were removed from KSU headers."
  set -e
  return 0
}

# For every ksu_* function core/init.c calls without a visible declaration,
# find the header that declares it and include it. Falls back to a local
# prototype. Also verifies afterwards that nothing is left undeclared, so this
# never silently hands a broken file to the compiler.
ensure_init_symbols_declared() {
  set +e
  local ksu_dir="$1"
  local init_c="${ksu_dir}/core/init.c"
  if [[ ! -f "$init_c" ]]; then
    set -e
    return 0
  fi

  local sym hdr rel decl_re anchor visible pass
  local unresolved=()

  # Two passes: the first adds includes, the second re-checks and reports.
  for pass in 1 2; do
    unresolved=()
    local called
    called="$(grep -oE '\bksu_[A-Za-z0-9_]+\(' "$init_c" | sed 's/(//' | sort -u)"

    for sym in $called; do
      decl_re="^[A-Za-z_][A-Za-z0-9_[:space:]\*]*[[:space:]\*]${sym}[[:space:]]*\("

      # Declared directly in init.c (a local prototype we added, or a static)?
      grep -qE "$decl_re" "$init_c" && continue

      # Declared in a header init.c includes, transitively one level deep?
      visible=0
      while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        [[ -f "${ksu_dir}/${rel}" ]] || continue
        if grep -qE "$decl_re" "${ksu_dir}/${rel}"; then
          visible=1
          break
        fi
        # one level of nesting: headers included by that header
        local nested
        while IFS= read -r nested; do
          [[ -f "${ksu_dir}/${nested}" ]] || continue
          if grep -qE "$decl_re" "${ksu_dir}/${nested}"; then
            visible=1
            break
          fi
        done < <(grep -oE '^#include[[:space:]]+"[^"]+"' "${ksu_dir}/${rel}" 2>/dev/null | sed -E 's/.*"([^"]+)".*/\1/')
        [[ "$visible" -eq 1 ]] && break
      done < <(grep -oE '^#include[[:space:]]+"[^"]+"' "$init_c" | sed -E 's/.*"([^"]+)".*/\1/')
      [[ "$visible" -eq 1 ]] && continue

      [[ "$pass" -eq 2 ]] && { unresolved+=("$sym"); continue; }

      anchor="$(_first_include_line "$init_c")"
      [[ -z "$anchor" ]] && continue

      hdr="$(grep -rlE "$decl_re" "$ksu_dir" --include='*.h' 2>/dev/null | head -n 1)"
      if [[ -n "$hdr" ]]; then
        rel="${hdr#"${ksu_dir}"/}"
        grep -Fq "#include \"${rel}\"" "$init_c" && continue
        sed -i "${anchor}a #include \"${rel}\"" "$init_c"
        echo "[+] core/init.c: ${sym} -> #include \"${rel}\""
      else
        sed -i "${anchor}a void ${sym}(void);" "$init_c"
        echo "[+] core/init.c: ${sym} -> local prototype void ${sym}(void);"
      fi
    done
  done

  if [[ "${#unresolved[@]}" -gt 0 ]]; then
    echo "::error::These symbols used by core/init.c are still undeclared:"
    printf '::error::  %s\n' "${unresolved[@]}"
    echo "==== core/init.c include block ===="
    grep -n '^#include' "$init_c" | head -n 40
    set -e
    return 1
  fi

  echo "[+] Every ksu_* symbol used by core/init.c has a visible declaration."
  set -e
  return 0
}

resolve_known_susfs_ksu_drift() {
  local ksu_repo_dir="$1"
  local ksu_dir="$2"
  local init_c="${ksu_dir}/core/init.c"
  local profile_h="${ksu_dir}/policy/app_profile.h"

  if [[ -f "$init_c" ]]; then
    if grep -q 'susfs_init();' "$init_c"; then
      echo "[+] init.c already calls susfs_init()."
    else
      awk '
        !done && /^[[:space:]]*ksu_supercalls_init\(\);[[:space:]]*$/ {
          print "#ifdef CONFIG_KSU_SUSFS"
          print "    susfs_init();"
          print "#endif // CONFIG_KSU_SUSFS"
          print ""
          done = 1
        }
        { print }
      ' "$init_c" > "${init_c}.new" && mv "${init_c}.new" "$init_c"

      grep -q 'susfs_init();' "$init_c" || {
        echo "::error::Could not inject susfs_init() into ${init_c}."
        exit 1
      }
      echo "[+] Injected susfs_init() into core/init.c."
    fi

    grep -q '#include <linux/susfs.h>' "$init_c" || {
      echo "::error::core/init.c calls susfs_init() but does not include <linux/susfs.h>."
      exit 1
    }
  fi

  if [[ -f "$profile_h" ]]; then
    sed -i 's/^void escape_to_root_for_init(void);$/int escape_to_root_for_init(void);/' "$profile_h"

    grep -q '^int escape_to_root_for_init(void);$' "$profile_h" || {
      echo "::error::Failed to fix the escape_to_root_for_init() prototype in ${profile_h}."
      cat -n "$profile_h"
      exit 1
    }
    echo "[+] app_profile.h: escape_to_root_for_init() prototype now returns int."
  fi

  restore_includes_deleted_by_susfs_patch "$ksu_repo_dir"
  restore_declarations_deleted_from_ksu_headers "$ksu_repo_dir"
  ensure_init_symbols_declared "$ksu_dir" || exit 1
}

susfs_reject_is_known() {
  case "$1" in
    */kernel/Kbuild.rej) return 0 ;;
    */kernel/core/init.c.rej) return 0 ;;
    */kernel/policy/app_profile.h.rej) return 0 ;;
    *) return 1 ;;
  esac
}

patch_kernelsu_for_susfs() {
  local ksu_repo_dir="$1"
  local ksu_dir="$2"
  local patch_name="10_enable_susfs_for_ksu.patch"
  local patch_file="${ksu_repo_dir}/${patch_name}"
  local kconfig_file="${ksu_dir}/Kconfig"

  test -f "$kconfig_file" || {
    echo "::error::KernelSU Kconfig not found at $kconfig_file"
    exit 1
  }

  if grep -q 'KSU_SUSFS' "$kconfig_file"; then
    echo "[+] KernelSU tree already contains KSU_SUSFS entries (native susfs support)."
    return 0
  fi

  test -f "$patch_file" || {
    echo "::error::Missing KernelSU susfs patch at $patch_file"
    exit 1
  }

  echo "==== Applying susfs KernelSU patch (git apply --reject) ===="
  git -C "$ksu_repo_dir" apply --reject --whitespace=nowarn "$patch_name" 2>&1 || true

  local unexpected=0
  local rej
  while IFS= read -r rej; do
    [[ -z "$rej" ]] && continue
    if susfs_reject_is_known "$rej"; then
      echo "[i] Known drift, handled explicitly: ${rej#"$ksu_repo_dir"/}"
    else
      echo "########## UNEXPECTED REJECT: ${rej} ##########"
      cat "$rej"
      echo
      local target="${rej%.rej}"
      if [[ -f "$target" ]]; then
        echo "########## CURRENT ${target} ##########"
        cat -n "$target"
        echo
      fi
      unexpected=1
    fi
  done < <(find "$ksu_repo_dir" -name '*.rej' | sort)

  if [[ "$unexpected" -ne 0 ]]; then
    echo "::error::susfs KernelSU patch produced rejects we do not know how to resolve."
    exit 1
  fi

  resolve_known_susfs_ksu_drift "$ksu_repo_dir" "$ksu_dir"

  find "$ksu_repo_dir" -name '*.rej' -delete
  find "$ksu_repo_dir" -name '*.orig' -delete

  grep -q 'KSU_SUSFS' "$kconfig_file" || {
    echo "::error::KSU_SUSFS is missing from $kconfig_file after patching."
    exit 1
  }

  echo "[+] susfs KernelSU patch applied; known drift resolved; KSU_SUSFS wired in."
}

patch_resukisu_susfs_runtime_compat() {
  local ksu_kernel_dir="$1"
  local runtime_file="${ksu_kernel_dir}/runtime/ksud_integration.c"

  [[ -f "$runtime_file" ]] || return 0
  grep -q 'CONFIG_KSU_SUSFS' "$runtime_file" || return 0

  if grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
    echo "[+] Runtime already contains native susfs hook support."
    return 0
  fi

  sed -i \
    -e 's/^extern struct static_key_false ksu_init_rc_hook_key_false;$/extern struct static_key_true ksu_is_init_rc_hook_enabled;/' \
    -e 's/^extern struct static_key_false ksu_input_hook_key_false;$/extern struct static_key_true ksu_is_input_hook_enabled;/' \
    -e 's/^#define ksu_init_rc_hook ksu_init_rc_hook_key_false$/#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled/' \
    -e 's/^#define ksu_input_hook ksu_input_hook_key_false$/#define ksu_input_hook ksu_is_input_hook_enabled/' \
    "$runtime_file"

  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "#define ksu_init_rc_hook_key_false ksu_is_init_rc_hook_enabled"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "#define ksu_input_hook_key_false ksu_is_input_hook_enabled"

  grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" || {
    echo "::error::Failed to inject ksu_is_init_rc_hook_enabled compatibility into ${runtime_file}"
    exit 1
  }

  grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" || {
    echo "::error::Failed to inject ksu_is_input_hook_enabled compatibility into ${runtime_file}"
    exit 1
  }

  if ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled$' "$runtime_file" && \
     ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file"; then
    echo "::error::Failed to retarget init_rc hook to the susfs static key in ${runtime_file}"
    exit 1
  fi

  if ! grep -Eq '^[[:space:]]*#define ksu_input_hook ksu_is_input_hook_enabled$' "$runtime_file" && \
     ! grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
    echo "::error::Failed to retarget input hook to the susfs static key in ${runtime_file}"
    exit 1
  fi
}

patch_susfs_selinux_hide_compat() {
  local ksu_kernel_dir="$1"
  local kbuild_file="${ksu_kernel_dir}/Kbuild"
  [[ -f "$kbuild_file" ]] || kbuild_file="${ksu_kernel_dir}/Makefile"
  local compat_dir="${ksu_kernel_dir}/compat"
  local compat_file="${compat_dir}/susfs_selinux_hide_compat.c"
  local compat_obj_line='kernelsu-objs += compat/susfs_selinux_hide_compat.o'
  local fake_state_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*struct[[:space:]]+selinux_state[[:space:]]+fake_state([[:space:];=]|$)'
  local running_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*bool[[:space:]]+ksu_selinux_hide_running([[:space:];=]|$)'

  if grep -R --exclude='susfs_selinux_hide_compat.c' -Eq "$fake_state_def_re" "$ksu_kernel_dir" && \
     grep -R --exclude='susfs_selinux_hide_compat.c' -Eq "$running_def_re" "$ksu_kernel_dir"; then
    if [[ -f "$kbuild_file" ]]; then
      sed -i "\|^${compat_obj_line}$|d" "$kbuild_file"
    fi
    rm -f "$compat_file"
    echo "[+] KernelSU tree already exports susfs SELinux hide compatibility symbols."
    return 0
  fi

  test -f "$kbuild_file" || {
    echo "::error::KernelSU Kbuild not found at $kbuild_file"
    exit 1
  }

  mkdir -p "$compat_dir"
  cat > "$compat_file" <<'EOF_COMPAT'
#include <linux/cache.h>
#include <linux/types.h>
#include "security.h"

#ifdef CONFIG_KSU_SUSFS
struct selinux_state fake_state;
bool ksu_selinux_hide_running __read_mostly = false;
#endif
EOF_COMPAT

  ensure_line_in_file "$kbuild_file" "$compat_obj_line"
  echo "[+] Added susfs SELinux hide compatibility symbols for this KernelSU tree."
}

apply_susfs_full() {
  local susfs_ref="$1"
  local susfs_patch_file="$2"
  local ksu_driver_dir ksu_kernel_dir ksu_repo_dir

  ksu_driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found before applying susfs"
    exit 1
  }
  ksu_kernel_dir="$(readlink -f "${ksu_driver_dir}/kernelsu")"
  ksu_repo_dir="$(dirname "${ksu_kernel_dir}")"

  git clone --depth=1 --no-tags -b "$susfs_ref" \
    https://gitlab.com/simonpunk/susfs4ksu.git susfs

  echo "==== SUSFS SOURCE ===="
  echo "branch: $susfs_ref"
  ( cd susfs && git log -1 --format='commit: %H%ncommit date: %ci' ) || true
  grep -E '^#define SUSFS_VERSION' ./susfs/kernel_patches/include/linux/susfs.h 2>/dev/null || true
  echo "==== KSU SOURCE ===="
  git -C "$ksu_repo_dir" log -1 --format='commit: %H%ncommit date: %ci' 2>/dev/null || true

  (
    cd susfs
    cp "./kernel_patches/${susfs_patch_file}" ..
    cp ./kernel_patches/fs/* ../fs/
    cp ./kernel_patches/include/linux/* ../include/linux/
  )

  cp ./susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "${ksu_repo_dir}/"
  mkdir -p "${ksu_kernel_dir}/include/linux"
  cp ./susfs/kernel_patches/include/linux/* "${ksu_kernel_dir}/include/linux/"
  patch_kernelsu_for_susfs "${ksu_repo_dir}" "${ksu_kernel_dir}"
  patch_resukisu_susfs_runtime_compat "${ksu_kernel_dir}"
  patch_susfs_selinux_hide_compat "${ksu_kernel_dir}"

  test -f include/linux/susfs_def.h || {
    echo "::error::susfs_def.h was not copied into include/linux from $susfs_ref"
    exit 1
  }

  test -f "${ksu_kernel_dir}/include/linux/susfs_def.h" || {
    echo "::error::susfs_def.h was not copied into ${ksu_kernel_dir}/include/linux"
    exit 1
  }

  if ! patch -p1 --batch --forward < "${susfs_patch_file}"; then
    echo "[!] susfs patch reported conflicts, checking for known task_mmu.c drift..."

    local reject_files reject_count
    reject_files="$(find . -name "*.rej" | sort)"
    reject_count="$(printf '%s\n' "$reject_files" | sed '/^$/d' | wc -l)"

    if [[ "$reject_count" -eq 1 ]] && [[ "$reject_files" == "./fs/proc/task_mmu.c.rej" ]] && grep -q 'susfs_def.h' ./fs/proc/task_mmu.c.rej; then
      apply_susfs_task_mmu_fix
      rm -f ./fs/proc/task_mmu.c.rej
      echo "[+] Resolved known susfs task_mmu.c patch drift."
    else
      echo "==== PATCH FAILED ===="
      find . -name "*.rej" -print -exec sh -c 'echo "---- $1 ----"; cat "$1"' _ {} \;
      exit 1
    fi
  fi

  patch_susfs_kernelsu_layout

  export KSU_KERNEL_DIR="$ksu_kernel_dir"
  export KSU_REPO_DIR="$ksu_repo_dir"
}
