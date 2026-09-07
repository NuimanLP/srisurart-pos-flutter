// AppBreakpoints — the single source of truth for responsive width thresholds.
//
// The responsive audit found every screen inventing its own magic number
// (AppShell 1000, Checkout 900, cash_drawer 760, reports 900, customers
// 600/700). Centralise them here so thresholds are intentional and consistent
// across phone / tablet / desktop. All values are logical pixels (dp).
//
// Tiers:  phone   < [compact]      (e.g. 360–414dp)
//         tablet  [compact]…[expanded)   (iPad 600–1000dp)
//         desktop ≥ [expanded]     (shop PC / web)

class AppBreakpoints {
  AppBreakpoints._();

  /// Phone ↔ tablet boundary.
  static const double compact = 600;

  /// Tablet ↔ desktop boundary.
  static const double expanded = 1000;

  /// Width at/above which the AppShell shows a persistent NavigationRail
  /// instead of a hamburger Drawer. Lowered below [expanded] so iPad portrait
  /// (768–834dp) gets a real tablet frame rather than a stretched phone.
  static const double rail = 760;

  /// Width at/above which the Checkout product+cart two-pane split is roomy
  /// enough (the cart pane is a fixed 400dp, so this stays high).
  static const double checkoutTwoPane = 900;

  static bool isPhone(double width) => width < compact;
  static bool isTablet(double width) => width >= compact && width < expanded;
  static bool isDesktop(double width) => width >= expanded;
}
