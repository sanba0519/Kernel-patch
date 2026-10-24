#!/bin/sh
#
# susfs_compat_nofail.sh
#
# 关掉 BakaSU 在 <KSU_SRC>/tools/susfs_compat.mk 里的"无条件拒绝构建"：
#
#   $(info -- $(REPO_NAME): susfs has NOT update with latest KernelSU source)
#   $(info -- $(REPO_NAME): Please wait simonpunk update)
#   $(error Please wait susfs update.)
#
# 这几行本意是"等 simonpunk 更新 SUSFS"，但它是无条件执行的，
# 任何 kernel-side SUSFS（包括 v2.3.0）都会被它挡死。
#
# 生产环境原则：**要么确实改干净了，要么大声失败（非 0 退出）**，
# 绝不出现"脚本说成功、构建却还是被拦"的情况。
#
#   * 不是内核源码树                        → 1
#   * 找不到 KernelSU（未集成）              → 1（--allow-missing 时降级为 0）
#   * KSU 目录存在但没 tools/susfs_compat.mk → 1
#   * 改完仍有未注释的 $(error ...)          → 1（打印残留行）
#   * 备份 / 替换失败                        → 1
#   * 写完复查不干净                         → 1（自动用 .bak 回滚）
#   * 本来就是处理过的状态                   → 0（幂等，算成功）
#
# 其它：
#   * 放到内核源码根目录即可直接跑，也能用绝对路径从任意目录跑；
#   * 纯内容匹配，不看行号；行首是 # 的注释行不动（保证幂等）；
#   * 备份 .bak，落盘用同目录 mv 原子替换，避免写一半留下坏文件；
#   * 输出统一前缀 [OK] / [SKIP] / [FAIL]，方便流水线 grep。
#
# 用法：
#   ./susfs_compat_nofail.sh                     # 内核根目录下直接跑
#   /path/to/susfs_compat_nofail.sh              # 任意目录，靠脚本位置定位
#   ./susfs_compat_nofail.sh <KSU_SRC>           # 显式指定，如 KernelSU/kernel
#   ./susfs_compat_nofail.sh --allow-missing     # 未集成 KernelSU 时返回 0
#   KSU_SRC=KernelSU/kernel ./susfs_compat_nofail.sh
#
set -u

PROG=$(basename "$0")
MARK='# [susfs_compat_nofail]'

ALLOW_MISSING=0
KSU_ARG=""

while [ $# -gt 0 ]; do
	case $1 in
	-m | --allow-missing)
		ALLOW_MISSING=1
		shift
		;;
	-h | --help)
		sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		echo "$PROG: [FAIL] 未知参数：$1" >&2
		exit 1
		;;
	*)
		KSU_ARG=$1
		shift
		;;
	esac
done

ok()   { echo "$PROG: [OK] $*"; }
skip() { echo "$PROG: [SKIP] $*"; }
fail() { echo "$PROG: [FAIL] $*" >&2; }

# ---------------------------------------------------------- 定位内核根目录
self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || self_dir=""

is_kernel_tree() {
	[ -n "$1" ] && [ -f "$1/Makefile" ] && [ -d "$1/drivers" ] &&
		grep -q '^VERSION[[:space:]]*=' "$1/Makefile"
}

ROOT=""
for d in "$self_dir" "$(pwd)"; do
	if is_kernel_tree "$d"; then
		ROOT=$d
		break
	fi
done

if [ -z "$ROOT" ]; then
	fail "没找到内核源码根目录（需要 Makefile 里有 VERSION = 且存在 drivers/）"
	fail "把本脚本放到内核源码根目录后执行：cp $PROG <kernel>/ && cd <kernel> && ./$PROG"
	exit 1
fi

cd "$ROOT" || { fail "无法进入 $ROOT"; exit 1; }

# ---------------------------------------------------------- 定位 KernelSU
find_ksu_src() {
	if [ -n "$KSU_ARG" ] && [ -f "$KSU_ARG/tools/susfs_compat.mk" ]; then
		echo "$KSU_ARG"
		return 0
	fi
	if [ -n "${KSU_SRC:-}" ] && [ -f "$KSU_SRC/tools/susfs_compat.mk" ]; then
		echo "$KSU_SRC"
		return 0
	fi
	for d in drivers/kernelsu KernelSU/kernel drivers/KernelSU/kernel KernelSU; do
		if [ -f "$d/tools/susfs_compat.mk" ]; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

if ! KSU_SRC_FOUND=$(find_ksu_src); then
	if [ -n "$KSU_ARG" ] && [ -d "$KSU_ARG" ]; then
		fail "$KSU_ARG 存在，但里面没有 tools/susfs_compat.mk（KernelSU 版本不对？）"
		exit 1
	fi
	if [ "$ALLOW_MISSING" = "1" ]; then
		skip "未集成 KernelSU（找不到 tools/susfs_compat.mk），未做任何修改。"
		skip "（--allow-missing 生效，返回 0）"
		exit 0
	fi
	fail "未集成 KernelSU：找不到 tools/susfs_compat.mk，未做任何修改。"
	fail "已检查：drivers/kernelsu、KernelSU/kernel、drivers/KernelSU/kernel"
	fail "确认不需要处理请显式加 --allow-missing；路径不同请传入 <KSU_SRC>"
	exit 1
fi

F="$KSU_SRC_FOUND/tools/susfs_compat.mk"
[ -f "$F" ] || { fail "$F 不存在"; exit 1; }

# 未注释（行首不是 #）且含有 $(error ...) 的行
active_errors() {
	grep -nE '\$\(error' "$1" 2>/dev/null |
		grep -vE '^[0-9]+:[[:space:]]*#'
}

# ---------------------------------------------------------- 计算目标内容
TMP="$F.tmp.$$"
trap 'rm -f "$TMP"' EXIT INT TERM

# 规则 1：把"未注释且含 $(error ...)"的行整行注释掉
# 规则 2：把含 susfs has NOT update / Please wait simonpunk 的未注释 $(info ...) 行注释掉
# 用 [^#$]* 做前缀，保证已经是注释（以 # 开头）的行不会再被匹配 → 幂等
if ! sed -E \
	-e "s@^([[:space:]]*)([^#$]*)(\\\$\\(error.*)\$@\\1$MARK \\2\\3@" \
	-e "s@^([[:space:]]*)([^#$]*)(\\\$\\(info.*(susfs has NOT update|Please wait simonpunk).*)\$@\\1$MARK \\2\\3@" \
	"$F" > "$TMP"
then
	fail "处理 $F 失败（sed 出错），未做任何修改。"
	exit 1
fi

# 关键校验 1：改完还有 active 的 $(error ...) 说明没修掉 —— 直接失败
LEFT=$(active_errors "$TMP")
if [ -n "$LEFT" ]; then
	fail "$F 里仍有未注释的 \$(error ...)，本次未能修正："
	echo "$LEFT" | sed 's/^/    /' >&2
	fail "（多半是上游改了写法，请手工确认后重试）"
	exit 1
fi

if cmp -s "$F" "$TMP"; then
	ok "$F 无需修改（已经是处理过的状态）。"
	exit 0
fi

# ---------------------------------------------------------- 落盘（原子替换）
if ! cp -p "$F" "$F.bak"; then
	fail "无法备份 $F，未做任何修改。"
	exit 1
fi

chmod --reference="$F" "$TMP" 2>/dev/null || true

if ! mv -f "$TMP" "$F"; then
	fail "替换 $F 失败，原文件未动（备份：$F.bak）。"
	exit 1
fi

# 关键校验 2：写回后复查，仍不干净就回滚并失败
LEFT=$(active_errors "$F")
if [ -n "$LEFT" ]; then
	fail "写入后复查失败，$F 仍有未注释的 \$(error ...)："
	echo "$LEFT" | sed 's/^/    /' >&2
	if mv -f "$F.bak" "$F"; then
		fail "已从备份回滚 $F。"
	else
		fail "回滚失败！请手工用 $F.bak 恢复。"
	fi
	exit 1
fi

ok "已修改 $F（备份：$F.bak）"
grep -nF "$MARK" "$F" | sed 's/^/    /'
ok "完成。"
exit 0
