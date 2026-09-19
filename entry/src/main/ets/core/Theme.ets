/**
 * Theme —— 设计 token（S26）
 *
 * 目的：终结"每个页面自己发明颜色/字号/圆角"的局面。改造前的实测数据：
 *   文字灰 6 种（#1A1A2E/#666/#888/#999/#AAA/#555）
 *   近白背景 5 种（#F5F5FA/#F8F9FF/#F8F8FC/#F0F0F5/#F0F0FF）
 *   错误红 3 种、字号 11 档、圆角 9 档
 * 全部硬编码 → 改一处要翻遍所有文件，且深浅无规律。
 *
 * ⚠️ 颜色**不在这里定义常量**，而是在 resources/base/element/color.json 与
 *    resources/dark/element/color.json 各写一份，代码里用 $r('app.color.xxx') 引用 ——
 *    这样系统切深浅色时**自动生效**，不需要监听配置变化、也不需要重绘逻辑。
 *    这里只放"数值型" token（字号/圆角/间距/尺寸），那些不随主题变。
 */

/** 字号（收敛为 5 档 + 两个特殊） */
export class FontSize {
  /** 页面大标题 */
  static readonly TITLE: number = 22;
  /** 顶部栏标题 / 弹层标题 */
  static readonly HEADING: number = 17;
  /** 气泡正文 / 主要阅读文本 */
  static readonly BODY: number = 16;
  /** 列表项 / 按钮文字 */
  static readonly LABEL: number = 15;
  /** 辅助信息（时间、计数、说明）*/
  static readonly CAPTION: number = 13;
  /** 极小（角标）*/
  static readonly BADGE: number = 10;
}

/** 圆角（收敛为 3 档 + 胶囊） */
export class Radius {
  /** 气泡 */
  static readonly BUBBLE: number = 18;
  /** 卡片 / 面板 */
  static readonly CARD: number = 12;
  /** 小元素（标签、输入框内块）*/
  static readonly SMALL: number = 8;
  /** 胶囊（按钮、标签）*/
  static readonly PILL: number = 20;
}

/** 间距（4 的倍数）*/
export class Space {
  static readonly XS: number = 4;
  static readonly S: number = 8;
  static readonly M: number = 12;
  static readonly L: number = 16;
  static readonly XL: number = 24;
}

/** 常用尺寸 */
export class Size {
  /** 顶部栏高度 */
  static readonly HEADER_H: number = 52;
  /** 输入框高度 */
  static readonly INPUT_H: number = 44;
  /** 主按钮高度 */
  static readonly BUTTON_H: number = 40;
  /** 头像 / 图标按钮 */
  static readonly AVATAR: number = 32;
}

/** 颜色资源名集中说明（⚠️ 不在类里定义 $r() 常量：ArkTS 对资源引用的求值上下文有要求，
 *  写在模块级/静态属性里不保险。统一在组件里内联 $r('app.color.xxx')。
 *
 * 可用颜色名（base 与 dark 各一份，系统自动切换）：
 *   brand / brand_pressed / brand_soft
 *   text_primary / text_secondary / text_tertiary / text_on_brand
 *   bg_page / bg_card / bg_input / bg_hover
 *   divider / border_subtle
 *   danger / danger_soft / warning / success
 *   bubble_user_bg / bubble_user_text / bubble_bot_bg / bubble_bot_text
 *   scrim
 */
