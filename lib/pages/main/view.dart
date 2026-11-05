import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/floating_navigation_bar.dart';
import 'package:PiliPlus/common/widgets/flutter/pop_scope.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:PiliPlus/common/widgets/route_aware_mixin.dart';
import 'package:PiliPlus/models/common/nav_bar_config.dart';
import 'package:PiliPlus/pages/home/view.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/mobile_observer.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/status_bar_column.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends PopScopeState<MainApp>
    with RouteAware, RouteAwareMixin, WidgetsBindingObserver {
  final _mainController = Get.put(MainController());
  late EdgeInsets _padding;
  late ColorScheme _colorScheme;

  /// The side bar goes on the right, below the status bar: on iPhone Duo's inner display
  /// the system keeps the status bar in a column on the right edge, the only thing in it.
  bool _sideBarAtEnd = false;

  /// How far down that column the status bar (time, signal, battery) reaches. iOS gives
  /// the whole column as one inset, so this is an estimate from its width.
  double get _statusBarExtent => math.max(_padding.right * 1.3, 110.0);
  Brightness? _brightness;

  @override
  bool get initCanPop => false;

  @override
  void initState() {
    super.initState();
    addObserverMobile(this);
    if (Platform.isMacOS) {
      HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    }
    if (PlatformUtils.isDesktop) {
      WindowController.instance.init();
      TrayController.instance.init();
    }
    if (!Platform.isMacOS) {
      PiliScheme.init();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _padding = MediaQuery.viewPaddingOf(context);
    // also remembers the column for the video page, which may hide the status bar
    final statusBarAtEnd = StatusBarColumn.atEnd(
      _padding,
      MediaQuery.sizeOf(context),
    );
    _sideBarAtEnd = statusBarAtEnd && Pref.sideBarFollowStatusBar;
    _colorScheme = ColorScheme.of(context);
    final brightness = _colorScheme.brightness;
    NetworkImgLayer.reduce =
        NetworkImgLayer.reduceLuxColor != null && brightness.isDark;
    if (PlatformUtils.isDesktop) {
      if (_brightness != brightness) {
        _brightness = brightness;
        nativeapi.Application.instance.setBrightness(
          brightness == .dark ? .dark : .light,
        );
      }
    }
    if (!_mainController.useSideBar) {
      _mainController.useBottomNav = MediaQuery.sizeOf(context).isPortrait;
    }
  }

  @override
  void didPopNext() {
    addObserverMobile(this);
    _mainController
      ..checkUnreadDynamic()
      ..checkDefaultSearch(true)
      ..checkUnread(_mainController.useBottomNav);
    super.didPopNext();
  }

  @override
  void didPushNext() {
    removeObserverMobile(this);
    super.didPushNext();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _mainController
        ..checkUnreadDynamic()
        ..checkDefaultSearch(true)
        ..checkUnread(_mainController.useBottomNav);
    }
  }

  @override
  void dispose() {
    if (Platform.isMacOS) {
      HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    }
    if (PlatformUtils.isDesktop) {
      WindowController.instance.dispose();
      TrayController.instance.dispose();
    }
    removeObserverMobile(this);
    PiliScheme.listener?.cancel();
    GStorage.close();
    super.dispose();
  }

  bool _handleKeyEvent(KeyEvent event) {
    return event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyR &&
        HardwareKeyboard.instance.isMetaPressed &&
        _mainController.refreshRecommendations();
  }

  @pragma('vm:prefer-inline')
  static void _onBack() {
    if (Platform.isAndroid) {
      AndroidHelper.back();
    }
  }

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (_mainController.directExitOnBack) {
      _onBack();
    } else {
      if (_mainController.selectedIndex.value != 0) {
        _mainController
          ..setIndex(0)
          ..barOffset?.value = 0.0
          ..showBottomBar?.value = true
          ..setSearchBar();
      } else {
        _onBack();
      }
    }
  }

  Widget? get _bottomNav {
    Widget? bottomNav;
    if (_mainController.navigationBars.length > 1) {
      if (_mainController.floatingNavBar) {
        bottomNav = Obx(
          () => FloatingNavigationBar(
            onDestinationSelected: _mainController.setIndex,
            selectedIndex: _mainController.selectedIndex.value,
            destinations: _mainController.navigationBars
                .map(
                  (e) => FloatingNavigationDestination(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    selectedIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      } else if (_mainController.enableMYBar) {
        bottomNav = Obx(
          () => NavigationBar(
            maintainBottomViewPadding: true,
            onDestinationSelected: _mainController.setIndex,
            selectedIndex: _mainController.selectedIndex.value,
            destinations: _mainController.navigationBars
                .map(
                  (e) => NavigationDestination(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    selectedIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      } else {
        bottomNav = Obx(
          () => BottomNavigationBar(
            currentIndex: _mainController.selectedIndex.value,
            onTap: _mainController.setIndex,
            iconSize: 16,
            selectedFontSize: 12,
            unselectedFontSize: 12,
            type: .fixed,
            items: _mainController.navigationBars
                .map(
                  (e) => BottomNavigationBarItem(
                    label: e.label,
                    icon: _buildIcon(type: e),
                    activeIcon: _buildIcon(type: e, selected: true),
                  ),
                )
                .toList(),
          ),
        );
      }

      if (_mainController.hideBottomBar) {
        if (_mainController.barOffset case final barOffset?) {
          return Obx(
            () => FractionalTranslation(
              translation: Offset(
                0.0,
                barOffset.value / Style.topBarHeight,
              ),
              child: bottomNav,
            ),
          );
        }
        if (_mainController.showBottomBar case final showBottomBar?) {
          return Obx(
            () => AnimatedSlide(
              curve: Curves.easeInOutCubicEmphasized,
              duration: const Duration(milliseconds: 500),
              offset: Offset(0, showBottomBar.value ? 0 : 1),
              child: bottomNav,
            ),
          );
        }
      }
    }

    return bottomNav;
  }

  /// The side bar in the status bar's column (iPhone Duo's inner display): two floating
  /// capsules of icons, the account and search below the status bar and the pages at
  /// the bottom.
  Widget _sideBarInStatusBarColumn() {
    final colorScheme = _colorScheme;
    final decoration = ShapeDecoration(
      color: colorScheme.surfaceContainerLow,
      shape: StadiumBorder(
        side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.12)),
      ),
      shadows: [
        BoxShadow(
          color: colorScheme.shadow.withValues(alpha: 0.08),
          blurRadius: 12,
          offset: const Offset(0, 2),
        ),
      ],
    );
    Widget capsule(Widget child) => Container(
      width: 56,
      padding: const .symmetric(vertical: 8),
      decoration: decoration,
      child: child,
    );
    return SizedBox(
      width: math.max(80, _padding.right),
      child: MediaQuery.removePadding(
        context: context,
        removeLeft: true,
        removeRight: true,
        removeTop: true,
        removeBottom: true,
        child: Column(
          children: [
            SizedBox(height: _statusBarExtent),
            capsule(userAndSearchVertical()),
            const Spacer(),
            if (_mainController.navigationBars.length > 1)
              capsule(
                Obx(() {
                  final selectedIndex = _mainController.selectedIndex.value;
                  final navigationBars = _mainController.navigationBars;
                  return Column(
                    mainAxisSize: .min,
                    spacing: 4,
                    children: [
                      for (var i = 0; i < navigationBars.length; i++)
                        _capsuleDestination(
                          navigationBars[i],
                          i,
                          selected: i == selectedIndex,
                        ),
                    ],
                  );
                }),
              ),
            SizedBox(height: math.max(16, _padding.bottom + 8)),
          ],
        ),
      ),
    );
  }

  Widget _capsuleDestination(
    NavigationBarType type,
    int index, {
    required bool selected,
  }) {
    final colorScheme = _colorScheme;
    return IconButton(
      tooltip: type.label,
      isSelected: selected,
      onPressed: () => _mainController.setIndex(index),
      style: IconButton.styleFrom(
        backgroundColor: selected ? colorScheme.secondaryContainer : null,
        foregroundColor: selected
            ? colorScheme.onSecondaryContainer
            : colorScheme.onSurfaceVariant,
      ),
      icon: _buildIcon(type: type, selected: selected),
    );
  }

  Widget _sideBar() {
    if (_sideBarAtEnd) return _sideBarInStatusBarColumn();
    if (_mainController.navigationBars.length > 1) {
      if (context.isTablet && _mainController.optTabletNav) {
        return Padding(
          padding: const .only(top: 25),
          child: MediaQuery.removePadding(
            context: context,
            removeRight: true,
            child: Obx(
              () => DrawerTheme(
                data: DrawerThemeData(
                  width:
                      (_mainController.hideSideBarLabel ? 80 : 130) +
                      _padding.left,
                ),
                child: NavigationDrawer(
                  /// apply `lib/scripts/navigation_drawer.patch`
                  flex: 5,
                  backgroundColor: Colors.transparent,
                  onDestinationSelected: _mainController.setIndex,
                  selectedIndex: _mainController.selectedIndex.value,
                  header: Expanded(flex: 4, child: userAndSearchVertical()),
                  tilePadding: const .symmetric(vertical: 5, horizontal: 12),
                  indicatorShape: _mainController.hideSideBarLabel
                      ? const RoundedRectangleBorder(
                          borderRadius: .all(.circular(12)),
                        )
                      : const RoundedRectangleBorder(
                          borderRadius: .all(.circular(16)),
                        ),
                  children: _mainController.navigationBars
                      .map(
                        (e) => NavigationDrawerDestination(
                          label: _mainController.hideSideBarLabel
                              ? Semantics(
                                  label: e.label,
                                  child: const SizedBox.shrink(),
                                )
                              : Text(e.label),
                          icon: _buildIcon(type: e),
                          selectedIcon: _buildIcon(
                            type: e,
                            selected: true,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        );
      }
      return Obx(
        () => NavigationRail(
          groupAlignment: 0.5,
          labelType: _mainController.hideSideBarLabel ? .none : .selected,
          leading: userAndSearchVertical(),
          backgroundColor: Colors.transparent,
          onDestinationSelected: _mainController.setIndex,
          selectedIndex: _mainController.selectedIndex.value,
          destinations: _mainController.navigationBars
              .map(
                (e) => NavigationRailDestination(
                  label: Text(e.label),
                  icon: _buildIcon(type: e),
                  selectedIcon: _buildIcon(type: e, selected: true),
                ),
              )
              .toList(),
        ),
      );
    }
    return Container(
      width: 80,
      margin: .only(top: 12 + _padding.top, left: _padding.left),
      child: userAndSearchVertical(),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_mainController.mainTabBarView) {
      child = TabBarView(
        controller: _mainController.controller,
        physics: const NeverScrollableScrollPhysics(),
        scrollDirection: _mainController.useBottomNav ? .horizontal : .vertical,
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    } else {
      child = PageView(
        controller: _mainController.controller,
        physics: const NeverScrollableScrollPhysics(),
        children: _mainController.navigationBars.map((i) => i.page).toList(),
      );
    }

    Widget? sideBar;
    Widget? bottomNav;
    final EdgeInsets padding;
    if (_mainController.useBottomNav) {
      bottomNav = _bottomNav;
      if (bottomNav != null) {
        bottomNav = MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: bottomNav,
        );
      }
      padding = _padding.copyWith(bottom: 0);
    } else {
      // The capsules in the status bar's column need no divider.
      sideBar = _sideBarAtEnd
          ? _sideBar()
          : DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  right: BorderSide(
                    color: _colorScheme.outline.withValues(alpha: 0.06),
                  ),
                ),
              ),
              child: _sideBar(),
            );
      // On the right, the side bar takes the status bar's column itself.
      padding = _sideBarAtEnd
          ? .only(top: _padding.top, left: _padding.left)
          : .only(top: _padding.top, right: _padding.right);
    }

    child = Material(
      child: MainLayout(
        sideBarAtEnd: sideBar != null && _sideBarAtEnd,
        sideBar: sideBar,
        bottomNav: bottomNav,
        body: Padding(padding: padding, child: child),
      ),
    );

    if (PlatformUtils.isMobile) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarBrightness: _colorScheme.brightness,
          statusBarIconBrightness: _colorScheme.brightness.reverse,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarIconBrightness: _colorScheme.brightness.reverse,
        ),
        child: child,
      );
    }

    return child;
  }

  Widget _buildIcon({required NavigationBarType type, bool selected = false}) {
    final icon = selected ? type.selectIcon : type.icon;
    return type == .dynamics
        ? Obx(
            () {
              final dynCount = _mainController.dynCount.value;
              return Badge(
                isLabelVisible: dynCount > 0,
                label: _mainController.dynamicBadgeMode == .number
                    ? Text(dynCount.toString())
                    : null,
                padding: const .symmetric(horizontal: 6),
                child: icon,
              );
            },
          )
        : icon;
  }

  Widget userAndSearchVertical() {
    return Column(
      children: [
        userAvatar(colorScheme: _colorScheme, mainController: _mainController),
        const SizedBox(height: 8),
        msgBadge(_mainController),
        IconButton(
          tooltip: '搜索',
          icon: const Icon(
            Icons.search_outlined,
            semanticLabel: '搜索',
          ),
          onPressed: () => Get.toNamed('/search'),
        ),
      ],
    );
  }
}
