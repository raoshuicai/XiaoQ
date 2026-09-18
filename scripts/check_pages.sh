#!/usr/bin/env bash
# check_pages.sh —— 路由注册一致性校验
#
# 为什么需要这个脚本：
#   鸿蒙的 router.pushUrl('pages/XxxPage') 路径是字符串，编译器不做校验。
#   新增页面如果忘了改 main_pages.json，编译照样通过，但运行时跳转崩溃。
#   这是新增页面最高频的翻车点（方案 V2 §3 决策 7）。
#
# 校验三条：
#   1. pages/ 下的每个 .ets 都必须在 main_pages.json 注册
#   2. main_pages.json 里注册的路径必须真实存在（防删页面忘删注册）
#   3. core/AppRouter.ets 存在时（S1 之后），其常量值必须与注册表一致
#
# 用法（在项目根目录）：
#   bash scripts/check_pages.sh
# 退出码：0=全部通过，1=发现问题

set -u

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAGES_DIR="$PROJ_ROOT/entry/src/main/ets/pages"
PAGES_JSON="$PROJ_ROOT/entry/src/main/resources/base/profile/main_pages.json"
ROUTER_ETS="$PROJ_ROOT/entry/src/main/ets/core/AppRouter.ets"

pass=0
fail=0

echo "=============================================="
echo " 路由注册校验"
echo " 项目: $PROJ_ROOT"
echo "=============================================="

# ---------- 前置检查 ----------
if [ ! -f "$PAGES_JSON" ]; then
  echo "❌ 找不到 $PAGES_JSON"
  exit 1
fi
if [ ! -d "$PAGES_DIR" ]; then
  echo "❌ 找不到页面目录 $PAGES_DIR"
  exit 1
fi

# ---------- 1) 应有列表：pages/ 下所有 .ets ----------
expected="$(find "$PAGES_DIR" -maxdepth 1 -name '*.ets' -printf '%f\n' 2>/dev/null \
            | sed 's/\.ets$//' | sed 's|^|pages/|' | sort -u)"

# ---------- 2) 实际注册列表 ----------
registered="$(grep -oE '"pages/[^"]+"' "$PAGES_JSON" | tr -d '"' | sort -u)"

echo
echo "--- pages/ 目录实际文件 ($(echo "$expected" | grep -c . ) 个) ---"
echo "$expected" | sed 's/^/  /'

echo
echo "--- main_pages.json 已注册 ($(echo "$registered" | grep -c . ) 个) ---"
echo "$registered" | sed 's/^/  /'

# ---------- 3) 比对：漏注册 ----------
missing="$(comm -23 <(echo "$expected") <(echo "$registered"))"
if [ -n "$missing" ]; then
  echo
  echo "❌ 以下页面存在但未注册到 main_pages.json（运行时跳转会崩溃）:"
  echo "$missing" | sed 's/^/    /'
  echo "  修复：把它们加进 $PAGES_JSON 的 src 数组"
  fail=$((fail + $(echo "$missing" | grep -c .)))
else
  echo
  echo "✅ 无漏注册页面"
  pass=$((pass + 1))
fi

# ---------- 4) 比对：注册了但文件不存在 ----------
ghost="$(comm -13 <(echo "$expected") <(echo "$registered"))"
if [ -n "$ghost" ]; then
  echo
  echo "❌ 以下路径已注册但文件不存在（死引用）:"
  echo "$ghost" | sed 's/^/    /'
  echo "  修复：从 $PAGES_JSON 删掉，或补回对应 .ets 文件"
  fail=$((fail + $(echo "$ghost" | grep -c .)))
else
  echo "✅ 无死引用"
  pass=$((pass + 1))
fi

# ---------- 5) AppRouter.ets 一致性（S1 之后才存在） ----------
if [ -f "$ROUTER_ETS" ]; then
  echo
  echo "--- AppRouter.ets 常量一致性 ---"
  router_paths="$(grep -oE "static readonly [A-Z_]+: string = 'pages/[^']+'" "$ROUTER_ETS" \
                  | sed "s/.*= '//" | sed "s/'$//" | sort -u)"
  if [ -z "$router_paths" ]; then
    echo "  (未从 AppRouter.ets 解析到任何 pages/ 常量，跳过)"
  else
    router_bad="$(comm -23 <(echo "$router_paths") <(echo "$registered"))"
    if [ -n "$router_bad" ]; then
      echo "❌ AppRouter 里定义了但未注册的路径:"
      echo "$router_bad" | sed 's/^/    /'
      fail=$((fail + 1))
    else
      echo "✅ AppRouter 常量与注册表一致 ($(echo "$router_paths" | grep -c .) 个)"
      pass=$((pass + 1))
    fi
  fi
else
  echo
  echo "ℹ️  core/AppRouter.ets 尚未创建（S1 之后产生），跳过常量校验"
fi

# ---------- 汇总 ----------
echo
echo "=============================================="
if [ "$fail" -eq 0 ]; then
  echo " ✅ 校验通过（$pass 项）"
  echo "=============================================="
  exit 0
else
  echo " ❌ 发现 $fail 处问题，请修复后重跑"
  echo "=============================================="
  exit 1
fi
