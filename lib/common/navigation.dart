import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/views.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Navigation {
  static Navigation? _instance;
  static bool showHidden = false;

  static Future<void> initShowHidden() async {
    final prefs = await SharedPreferences.getInstance();
    showHidden = prefs.getBool('nav_show_hidden') ?? false;
  }

  static Future<void> setShowHidden(bool value) async {
    showHidden = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('nav_show_hidden', value);
  }

  List<NavigationItem> getItems({
    bool openLogs = false,
    bool hasProxies = false,
  }) {
    final items = <NavigationItem>[
      NavigationItem(
        keep: false,
        icon: Icon(Icons.space_dashboard),
        label: PageLabel.dashboard,
        builder: (_) =>
            const DashboardView(key: GlobalObjectKey(PageLabel.dashboard)),
      ),
      NavigationItem(
        icon: const Icon(Icons.article),
        label: PageLabel.proxies,
        builder: (_) =>
            const ProxiesView(key: GlobalObjectKey(PageLabel.proxies)),
        modes: hasProxies
            ? [NavigationItemMode.mobile, NavigationItemMode.desktop]
            : [],
      ),
      NavigationItem(
        icon: Icon(Icons.folder),
        label: PageLabel.profiles,
        modes: showHidden
            ? [NavigationItemMode.mobile, NavigationItemMode.desktop]
            : [],
        builder: (_) =>
            const ProfilesView(key: GlobalObjectKey(PageLabel.profiles)),
      ),
      NavigationItem(
        icon: const Icon(Icons.storefront),
        label: PageLabel.store,
        builder: (_) => const StoreView(key: GlobalObjectKey(PageLabel.store)),
      ),
      if (showHidden)
        NavigationItem(
          icon: Icon(Icons.view_timeline),
          label: PageLabel.requests,
          builder: (_) =>
              const RequestsView(key: GlobalObjectKey(PageLabel.requests)),
          description: 'requestsDesc',
          modes: [NavigationItemMode.desktop, NavigationItemMode.more],
        ),
      if (showHidden)
        NavigationItem(
          icon: Icon(Icons.ballot),
          label: PageLabel.connections,
          builder: (_) =>
              const ConnectionsView(key: GlobalObjectKey(PageLabel.connections)),
          description: 'connectionsDesc',
          modes: [NavigationItemMode.desktop, NavigationItemMode.more],
        ),
      if (showHidden)
        NavigationItem(
          icon: Icon(Icons.storage),
          label: PageLabel.resources,
          description: 'resourcesDesc',
          builder: (_) =>
              const ResourcesView(key: GlobalObjectKey(PageLabel.resources)),
          modes: [NavigationItemMode.more],
        ),
      NavigationItem(
        icon: const Icon(Icons.adb),
        label: PageLabel.logs,
        builder: (_) => const LogsView(key: GlobalObjectKey(PageLabel.logs)),
        description: 'logsDesc',
        modes: openLogs
            ? [NavigationItemMode.desktop, NavigationItemMode.more]
            : [],
      ),
      NavigationItem(
        icon: Icon(Icons.construction),
        label: PageLabel.tools,
        builder: (_) => const ToolsView(key: GlobalObjectKey(PageLabel.tools)),
        modes: [NavigationItemMode.desktop, NavigationItemMode.mobile],
      ),
    ];
    return items;
  }

  Navigation._internal();

  factory Navigation() {
    _instance ??= Navigation._internal();
    return _instance!;
  }
}

final navigation = Navigation();
