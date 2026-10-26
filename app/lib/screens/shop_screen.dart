import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/shop_provider.dart';
import '../providers/stats_provider.dart';
import '../providers/auth_provider.dart';
import '../models/shop_item.dart';
import '../services/ad_service.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/avatar_art.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/confetti_burst.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  ShopItem? _lastPurchasedItem; // 마지막 구매 시도한 아이템
  bool _ownedOnly = false; // '내 아이템' 보기

  final List<_TabInfo> _tabs = [
    _TabInfo(Icons.auto_awesome, '프레임', CandyColors.grape),
    _TabInfo(Icons.military_tech, '칭호', CandyColors.pink),
    _TabInfo(Icons.palette, '테마', CandyColors.sky),
    _TabInfo(Icons.face, '아바타', CandyColors.mint),
    _TabInfo(Icons.pets, '마스코트', CandyColors.grapeDeep),
    _TabInfo(Icons.confirmation_number, '티켓', CandyColors.tangerine),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 6, vsync: this);
    // 기간제 아이템이 그새 만료됐을 수 있으니 진입 시 보유/장착 상태를 갱신
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ShopProvider>().refreshOwnership();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // ---- 공용 캔디 헬퍼 ----

  /// 희귀도 → 캔디 팔레트 색.
  Color _rarityColor(Rarity r) {
    switch (r) {
      case Rarity.common:
        return const Color(0xFFB4ADC9);
      case Rarity.rare:
        return CandyColors.sky;
      case Rarity.epic:
        return CandyColors.grape;
      case Rarity.legendary:
        return CandyColors.tangerine;
    }
  }

  Color _tint(Color c, [double amount = 0.16]) =>
      Color.alphaBlend(c.withValues(alpha: amount), Colors.white);

  /// 코인 아이콘이 붙은 노란 가격/금액 칩.
  Widget _coinChip(String text, {double fontSize = 13, double iconSize = 16}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: CandyColors.sun,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.monetization_on_rounded,
            size: iconSize,
            color: CandyColors.sunDeep,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: CandyColors.ink,
                fontWeight: FontWeight.w900,
                fontSize: fontSize,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 바텀시트 공통 껍데기 장식.
  static const BoxDecoration _sheetDeco = BoxDecoration(
    color: CandyColors.cream,
    borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    border: Border(
      top: BorderSide(color: CandyColors.ink, width: 3),
      left: BorderSide(color: CandyColors.ink, width: 3),
      right: BorderSide(color: CandyColors.ink, width: 3),
    ),
  );

  Widget _sheetHandle() {
    return Container(
      width: 44,
      height: 6,
      decoration: BoxDecoration(
        color: CandyColors.ink,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }

  Widget _sheetTitle(String title, String sub) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w900,
            color: CandyColors.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          sub,
          style: const TextStyle(
            color: CandyColors.inkSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  /// 게임 선택 시트의 한 줄 (눌림 카드).
  Widget _gameRow({
    required Map<String, Object> game,
    required VoidCallback? onTap,
    String? subtitle,
    Color? subtitleColor,
    Widget? trailing,
  }) {
    final color = game['color'] as Color;
    final enabled = onTap != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Opacity(
        opacity: enabled ? 1 : 0.55,
        child: CartoonCard(
          onTap: onTap,
          shadow: 3,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: CandyColors.ink, width: 2.5),
                ),
                child: Icon(game['icon'] as IconData, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      game['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: CandyColors.ink,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: subtitleColor ?? CandyColors.inkSoft,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              trailing ??
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: CandyColors.ink,
                  ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: CandyColors.cream,
      body: FloatingBackground(
        child: Consumer2<ShopProvider, StatsProvider>(
          builder: (context, shopProvider, statsProvider, child) {
            // 메시지 표시
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (shopProvider.error != null) {
                _lastPurchasedItem = null; // 구매 실패 시 초기화
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(shopProvider.error!),
                    backgroundColor: Colors.red,
                  ),
                );
                shopProvider.clearMessages();
              }
              if (shopProvider.successMessage != null) {
                // 구매 성공 시 장착 여부 묻기
                final purchasedItem = _lastPurchasedItem;
                if (purchasedItem != null &&
                    shopProvider.successMessage!.contains('구매')) {
                  _lastPurchasedItem = null;
                  shopProvider.clearMessages();
                  statsProvider.getMileage();
                  _askEquipAfterPurchase(shopProvider, purchasedItem);
                } else {
                  if (shopProvider.lastChangedNickname != null) {
                    context.read<AuthProvider>().setNickname(
                      shopProvider.lastChangedNickname!,
                    );
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(shopProvider.successMessage!),
                      backgroundColor: Colors.green,
                    ),
                  );
                  shopProvider.clearMessages();
                  statsProvider.getMileage();
                }
              }
            });

            return NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) {
                return [
                  // 커스텀 AppBar
                  SliverAppBar(
                    expandedHeight: statsProvider.adEnabled ? 236 : 168,
                    floating: false,
                    pinned: true,
                    backgroundColor: CandyColors.pink,
                    foregroundColor: Colors.white,
                    flexibleSpace: FlexibleSpaceBar(
                      background: _buildCoinHeader(statsProvider),
                    ),
                    title: innerBoxIsScrolled ? const Text('코인 샵') : null,
                    leading: IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ),
                  // 탭바
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _SliverTabBarDelegate(
                      TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabAlignment: TabAlignment.start,
                        labelColor: CandyColors.ink,
                        unselectedLabelColor: CandyColors.inkSoft,
                        indicatorSize: TabBarIndicatorSize.tab,
                        dividerColor: Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        indicator: BoxDecoration(
                          borderRadius: BorderRadius.circular(25),
                          color: CandyColors.sun,
                          border: Border.all(
                            color: CandyColors.ink,
                            width: 2.5,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: CandyColors.ink,
                              offset: Offset(0, 3),
                            ),
                          ],
                        ),
                        tabs: _tabs.map((tab) => _buildTab(tab)).toList(),
                      ),
                      CandyColors.cream,
                    ),
                  ),
                ];
              },
              body: TabBarView(
                controller: _tabController,
                children: [
                  _buildItemGrid(shopProvider, ShopCategory.frame),
                  _buildItemGrid(shopProvider, ShopCategory.title),
                  _buildItemGrid(shopProvider, ShopCategory.theme),
                  _buildItemGrid(shopProvider, ShopCategory.avatar),
                  _buildItemGrid(shopProvider, ShopCategory.mascot),
                  _buildTicketList(shopProvider, statsProvider),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildTab(_TabInfo tab) {
    return Tab(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                color: tab.color,
                shape: BoxShape.circle,
                border: Border.all(color: CandyColors.ink, width: 2),
              ),
              child: Icon(tab.icon, size: 16, color: Colors.white),
            ),
            const SizedBox(width: 6),
            Text(
              tab.label,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCoinHeader(StatsProvider statsProvider) {
    final adEnabled = statsProvider.adEnabled;
    final remaining = statsProvider.adRemaining;
    final dailyLimit = statsProvider.adDailyLimit;
    final rewardCoins = statsProvider.adRewardCoins;
    final canWatch = remaining > 0 && !statsProvider.isLoading;

    return Container(
      color: CandyColors.pink,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, kToolbarHeight, 16, 14),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: math.min(
                    300,
                    MediaQuery.of(context).size.width - 32,
                  ),
                  maxWidth: math.max(
                    240,
                    MediaQuery.of(context).size.width - 32,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CartoonCard(
                      color: CandyColors.sun,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: CandyColors.ink,
                                width: CandyTheme.outline,
                              ),
                            ),
                            child: const Icon(
                              Icons.monetization_on_rounded,
                              color: CandyColors.sunDeep,
                              size: 34,
                            ),
                          ),
                          const SizedBox(width: 14),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '보유 코인',
                                  style: TextStyle(
                                    color: CandyColors.ink,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                TweenAnimationBuilder<double>(
                                  tween: Tween(
                                    begin: 0,
                                    end: statsProvider.mileage.toDouble(),
                                  ),
                                  duration: const Duration(milliseconds: 800),
                                  curve: Curves.easeOutCubic,
                                  builder: (context, v, _) => Text(
                                    '${v.round()}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: CandyColors.ink,
                                      fontSize: 34,
                                      fontWeight: FontWeight.w900,
                                      height: 1.05,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (adEnabled) ...[
                      const SizedBox(height: 12),
                      ChunkyButton(
                        onPressed: canWatch
                            ? () => _showAdReward(statsProvider)
                            : null,
                        height: 48,
                        radius: 24,
                        fontSize: 14,
                        color: CandyColors.mint,
                        textColor: CandyColors.ink,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              canWatch
                                  ? Icons.play_circle_filled
                                  : Icons.check_circle,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                canWatch ? '광고 보고 +$rewardCoins코인' : '오늘 광고 완료',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: CandyColors.ink,
                                  width: 2,
                                ),
                              ),
                              child: Text(
                                '$remaining/$dailyLimit',
                                style: const TextStyle(
                                  color: CandyColors.ink,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 목록 정렬 점수(낮을수록 앞). 추천/할인/신상이 먼저, 보유는 뒤(만료 임박 보유는 그 앞).
  int _rank(ShopProvider sp, ShopItem i) {
    if (sp.hasItem(i.id)) {
      return (sp.ownedRecord(i.id)?.isExpiringSoon ?? false) ? 9 : 10;
    }
    var r = 6;
    if (i.isFeatured) r -= 3;
    if (i.isOnSale) r -= 2;
    if (i.badge == 'new') r -= 1;
    return r;
  }

  /// 내 아이템 보기 정렬: 만료 임박 순, 영구는 뒤.
  int _ownedCompare(ShopProvider sp, ShopItem a, ShopItem b) {
    final ea = sp.ownedRecord(a.id)?.expiresAt;
    final eb = sp.ownedRecord(b.id)?.expiresAt;
    if (ea == null && eb == null) return a.rarity.index.compareTo(b.rarity.index);
    if (ea == null) return 1;
    if (eb == null) return -1;
    return ea.compareTo(eb);
  }

  /// 추천 / 신상 / 할인 중 가로 스트립에 들어갈 아이템(안 가진 것만).
  List<ShopItem> _highlightItems(ShopProvider sp) {
    final list = sp.shopItems
        .where(
          (i) =>
              i.category != ShopCategory.ticket &&
              !sp.hasItem(i.id) &&
              (i.isFeatured || i.badge == 'new' || i.isOnSale),
        )
        .toList()
      ..sort((a, b) => _rank(sp, a).compareTo(_rank(sp, b)));
    return list.take(12).toList();
  }

  Widget _buildItemGrid(ShopProvider shopProvider, ShopCategory category) {
    final items = shopProvider.getItemsByCategory(category);

    if (shopProvider.isLoading && items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DuoMascot(size: 90, mood: MascotMood.wink),
            SizedBox(height: 16),
            CircularProgressIndicator(color: CandyColors.pink),
          ],
        ),
      );
    }

    if (items.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DuoMascot(size: 100, mood: MascotMood.sad),
            SizedBox(height: 12),
            Text(
              '아이템이 없습니다',
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontWeight: FontWeight.w900,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    // 정렬: 추천/할인/신상 → 희귀도, 보유는 뒤. 내 아이템 보기는 만료 임박 순.
    final List<ShopItem> sortedItems;
    if (_ownedOnly) {
      sortedItems = items.where((i) => shopProvider.hasItem(i.id)).toList()
        ..sort((a, b) => _ownedCompare(shopProvider, a, b));
    } else {
      sortedItems = List<ShopItem>.from(items)
        ..sort((a, b) {
          final ra = _rank(shopProvider, a), rb = _rank(shopProvider, b);
          if (ra != rb) return ra.compareTo(rb);
          return a.rarity.index.compareTo(b.rarity.index);
        });
    }
    final highlights = _ownedOnly
        ? const <ShopItem>[]
        : _highlightItems(shopProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 1350
            ? 5
            : width >= 1080
            ? 4
            : width >= 760
            ? 3
            : 2;
        final horizontalPadding = width >= 900 ? 24.0 : 16.0;

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildFilterBar(horizontalPadding)),
            if (highlights.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildHighlightStrip(
                  shopProvider,
                  highlights,
                  horizontalPadding,
                ),
              ),
            if (sortedItems.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    '보유한 아이템이 없어요',
                    style: TextStyle(
                      color: CandyColors.inkSoft,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  6,
                  horizontalPadding,
                  28,
                ),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    childAspectRatio: width >= 900 ? 0.78 : 0.68,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                  ),
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final item = sortedItems[index];
                    return PopIn(
                      delay: Duration(milliseconds: math.min(index * 40, 400)),
                      child: _buildItemCard(shopProvider, item),
                    );
                  }, childCount: sortedItems.length),
                ),
              ),
          ],
        );
      },
    );
  }

  /// '전체 / 내 아이템' 전환 알약.
  Widget _buildFilterBar(double hPad) {
    Widget pill(String label, bool selected, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? CandyColors.sun : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: CandyColors.ink, width: 2.5),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: CandyColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 13,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 6),
      child: Row(
        children: [
          pill('전체', !_ownedOnly, () => setState(() => _ownedOnly = false)),
          const SizedBox(width: 8),
          pill('내 아이템', _ownedOnly, () => setState(() => _ownedOnly = true)),
        ],
      ),
    );
  }

  /// 상단 '추천 / 신상 / 할인 중' 가로 스트립.
  Widget _buildHighlightStrip(
    ShopProvider sp,
    List<ShopItem> items,
    double hPad,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: _buildSectionHeader(
              '추천 · 신상 · 할인 중',
              Icons.local_fire_department,
              CandyColors.tangerine,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 156,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 6),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, i) => _buildHighlightTile(sp, items[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHighlightTile(ShopProvider sp, ShopItem item) {
    final rc = _rarityColor(item.rarity);
    return SizedBox(
      width: 118,
      child: CartoonCard(
        onTap: () => _showItemDialog(
          sp,
          item,
          sp.hasItem(item.id),
          sp.isEquipped(item.id),
        ),
        color: _tint(rc),
        padding: const EdgeInsets.all(6),
        radius: 20,
        shadow: 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: CandyColors.ink, width: 2.5),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _buildItemPreview(item),
                        ),
                      ),
                    ),
                    Positioned(top: 3, left: 3, child: _badgeRibbon(item)),
                    if (item.isOnSale)
                      Positioned(right: 3, bottom: 3, child: _saleSticker(item)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 12,
                color: CandyColors.ink,
              ),
            ),
            const SizedBox(height: 2),
            Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: item.price == 0
                    ? const Text(
                        '무료',
                        style: TextStyle(
                          color: CandyColors.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      )
                    : _coinChip('${item.price}', fontSize: 11, iconSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ribbon(String text, Color color, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: CandyColors.ink, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: Colors.white),
            const SizedBox(width: 2),
          ],
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  /// 한정 판매 남은 기간 짧은 표기: 'D-3' / '5시간'.
  String _shortLeft(Duration d) {
    if (d.inDays >= 1) return 'D-${d.inDays}';
    if (d.inHours >= 1) return '${d.inHours}시간';
    return '${math.max(d.inMinutes, 1)}분';
  }

  /// 'N일 남음' / 'N시간 남음' / 'N분 남음'.
  String _leftText(Duration d) {
    if (d.inDays > 0) return '${d.inDays}일 남음';
    if (d.inHours > 0) return '${d.inHours}시간 남음';
    return '${math.max(d.inMinutes, 1)}분 남음';
  }

  /// NEW / HOT / 한정(카운트다운) / 추천 리본. 해당 없으면 빈 위젯.
  Widget _badgeRibbon(ShopItem item) {
    final badge = item.badge ?? (item.availableUntil != null ? 'limited' : null);
    switch (badge) {
      case 'new':
        return _ribbon('NEW', CandyColors.pink, icon: Icons.auto_awesome);
      case 'hot':
        return _ribbon(
          'HOT',
          CandyColors.tangerine,
          icon: Icons.local_fire_department,
        );
      case 'limited':
        final left = item.availableLeft;
        return _ribbon(
          left != null && !left.isNegative ? '한정 ${_shortLeft(left)}' : '한정',
          CandyColors.grape,
          icon: Icons.timer,
        );
    }
    if (item.isFeatured) {
      return _ribbon('추천', CandyColors.skyDeep, icon: Icons.star_rounded);
    }
    return const SizedBox.shrink();
  }

  /// 빨간 '-N%' 스티커.
  Widget _saleSticker(ShopItem item) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFF3B4E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: CandyColors.ink, width: 2),
      ),
      child: Text(
        '-${item.discountPercent}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _durationChip(int days) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: CandyColors.ink, width: 2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timer_outlined, size: 11, color: CandyColors.ink),
          const SizedBox(width: 2),
          Text(
            '$days일',
            style: const TextStyle(
              color: CandyColors.ink,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildItemCard(ShopProvider shopProvider, ShopItem item) {
    final hasItem = shopProvider.hasItem(item.id);
    final isEquipped = shopProvider.isEquipped(item.id);
    final rc = _rarityColor(item.rarity);
    final rec = shopProvider.ownedRecord(item.id);
    final expiring = rec?.isExpiringSoon ?? false;

    return CartoonCard(
      onTap: () => _showItemDialog(shopProvider, item, hasItem, isEquipped),
      color: isEquipped ? _tint(CandyColors.mint, 0.35) : _tint(rc),
      padding: const EdgeInsets.all(8),
      radius: 22,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 프리뷰 영역
          Expanded(
            flex: 5,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _buildItemPreview(item),
                      ),
                    ),
                  ),
                  // 장착 중 / 보유 중 리본
                  if (isEquipped)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: _ribbon(
                        '장착중',
                        CandyColors.mintDeep,
                        icon: Icons.check_circle,
                      ),
                    ),
                  if (hasItem && !isEquipped)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: _ribbon('보유', CandyColors.sky),
                    ),
                  // 신상 / 인기 / 한정 배지 (안 가진 아이템만)
                  if (!hasItem)
                    Positioned(top: 4, right: 4, child: _badgeRibbon(item)),
                  // 만료 임박 경고
                  if (expiring)
                    Positioned(
                      left: 4,
                      bottom: 4,
                      child: _ribbon(
                        '곧 만료!',
                        const Color(0xFFFF3B4E),
                        icon: Icons.warning_amber_rounded,
                      ),
                    ),
                  if (!hasItem && item.isOnSale)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: _saleSticker(item),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 정보 영역
          Expanded(
            flex: 3,
            child: LayoutBuilder(
              builder: (context, c) => FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.topCenter,
                child: SizedBox(
                  width: c.maxWidth,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          // 희귀도 뱃지
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: rc,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: CandyColors.ink,
                                width: 2,
                              ),
                            ),
                            child: Text(
                              item.rarity.displayName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          if (item.durationDays != null &&
                              item.category != ShopCategory.ticket &&
                              !hasItem) ...[
                            const SizedBox(width: 6),
                            _durationChip(item.durationDays!),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 이름
                      Text(
                        item.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 14,
                          color: CandyColors.ink,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      // 가격/상태
                      _buildPriceOrStatus(item, hasItem, isEquipped, rec),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPriceOrStatus(
    ShopItem item,
    bool hasItem,
    bool isEquipped,
    UserItem? rec,
  ) {
    if (hasItem) {
      // 기간제 보유: 남은 기간 (임박하면 빨강)
      if (rec != null && rec.expiresAt != null) {
        final red = rec.isExpiringSoon;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: red ? const Color(0xFFFFE0E3) : Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: red ? const Color(0xFFFF3B4E) : CandyColors.ink,
              width: 2,
            ),
          ),
          child: Text(
            red ? rec.shortLeftText : '${rec.shortLeftText} · ${rec.expiresInText}',
            style: TextStyle(
              color: red ? const Color(0xFFD01E31) : CandyColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 11,
            ),
          ),
        );
      }
      return const SizedBox.shrink();
    }

    if (item.price == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: CandyColors.mint,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: CandyColors.ink, width: 2.5),
        ),
        child: const Text(
          '무료',
          style: TextStyle(
            color: CandyColors.ink,
            fontWeight: FontWeight.w900,
            fontSize: 12,
          ),
        ),
      );
    }

    final chip = _coinChip('${item.price}', fontSize: 12, iconSize: 15);
    if (!item.isOnSale) return chip;
    final left = item.saleEndsAt?.difference(DateTime.now());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            chip,
            const SizedBox(width: 6),
            Text(
              '${item.originalPrice}',
              style: const TextStyle(
                color: CandyColors.inkSoft,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                decoration: TextDecoration.lineThrough,
              ),
            ),
          ],
        ),
        if (left != null && !left.isNegative)
          Text(
            _leftText(left),
            style: const TextStyle(
              color: Color(0xFFD01E31),
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
      ],
    );
  }

  Widget _buildItemPreview(ShopItem item) {
    switch (item.category) {
      case ShopCategory.frame:
        return _buildFramePreview(item);
      case ShopCategory.title:
        return _buildTitlePreview(item);
      case ShopCategory.theme:
        return _buildThemePreview(item);
      case ShopCategory.avatar:
        return _buildAvatarPreview(item);
      case ShopCategory.mascot:
        return _buildMascotPreview(item);
      case ShopCategory.ticket:
        return _buildTicketPreview(item);
    }
  }

  Widget _buildFramePreview(ShopItem item) {
    final isRainbow = item.isRainbow;
    final borderColor = item.borderColor ?? CandyColors.inkSoft;

    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: isRainbow
            ? const SweepGradient(
                colors: [
                  Colors.red,
                  Colors.orange,
                  Colors.yellow,
                  Colors.green,
                  Colors.blue,
                  Colors.purple,
                  Colors.red,
                ],
              )
            : null,
        border: !isRainbow ? Border.all(color: borderColor, width: 4) : null,
        boxShadow: item.glowColor != null
            ? [
                BoxShadow(
                  color: item.glowColor!.withValues(alpha: 0.5),
                  blurRadius: 8,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: isRainbow
          ? Container(
              margin: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: const Icon(
                Icons.person,
                size: 40,
                color: CandyColors.inkSoft,
              ),
            )
          : const Icon(Icons.person, size: 40, color: CandyColors.inkSoft),
    );
  }

  Widget _buildTitlePreview(ShopItem item) {
    final textColor = item.textColor ?? CandyColors.inkSoft;
    final icon = item.titleIcon;
    final gradient = item.titleGradient;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null) Text(icon, style: const TextStyle(fontSize: 32)),
        const SizedBox(height: 4),
        ShaderMask(
          shaderCallback: (bounds) {
            if (gradient != null && gradient.length >= 2) {
              return LinearGradient(colors: gradient).createShader(bounds);
            }
            return LinearGradient(
              colors: [textColor, textColor],
            ).createShader(bounds);
          },
          child: Text(
            item.name,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildThemePreview(ShopItem item) {
    final colors =
        item.gradientColors ?? [CandyColors.inkSoft, const Color(0xFFD9D4E4)];

    return Container(
      width: 80,
      height: 60,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        boxShadow: [
          BoxShadow(
            color: colors[0].withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: item.particleType != null
          ? Center(
              child: Icon(
                _getParticleIcon(item.particleType!),
                color: Colors.white.withValues(alpha: 0.8),
                size: 24,
              ),
            )
          : null,
    );
  }

  Widget _buildAvatarPreview(ShopItem item) {
    return AvatarArt(
      itemKey: item.itemKey,
      emoji: item.avatarEmoji,
      bgColor: item.avatarBgColor,
      size: 76,
    );
  }

  Widget _buildMascotPreview(ShopItem item) {
    return DuoMascot(
      size: 78,
      color: item.mascotSkinColor ?? CandyColors.pink,
      accessory: item.mascotAccessory,
      animate: false,
    );
  }

  IconData _getParticleIcon(String particleType) {
    switch (particleType) {
      case 'stars':
        return Icons.star;
      case 'bubbles':
        return Icons.bubble_chart;
      case 'leaves':
        return Icons.eco;
      case 'fire':
        return Icons.local_fire_department;
      case 'neon':
        return Icons.lightbulb;
      case 'aurora':
        return Icons.waves;
      default:
        return Icons.auto_awesome;
    }
  }

  Widget _buildTicketPreview(ShopItem item) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(item.ticketIcon ?? '', style: const TextStyle(fontSize: 40)),
        const SizedBox(height: 4),
        Text(
          item.name,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w900,
            color: CandyColors.ink,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildTicketList(
    ShopProvider shopProvider,
    StatsProvider statsProvider,
  ) {
    final tickets = shopProvider.getItemsByCategory(ShopCategory.ticket);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final maxContentWidth = width >= 1300 ? 1040.0 : double.infinity;
        final horizontalPadding = width >= 900 ? 24.0 : 16.0;

        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                16,
                horizontalPadding,
                16,
              ),
              children: [
                _buildSectionHeader(
                  '특별 티켓',
                  Icons.local_activity,
                  CandyColors.sun,
                ),
                const SizedBox(height: 12),
                ...tickets.asMap().entries.map(
                  (e) => PopIn(
                    delay: Duration(milliseconds: math.min(e.key * 60, 400)),
                    child: _buildTicketCard(
                      shopProvider,
                      statsProvider,
                      e.value,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _buildSectionHeader(
                  '기타 서비스',
                  Icons.build_circle,
                  CandyColors.grape,
                ),
                const SizedBox(height: 12),
                PopIn(
                  delay: const Duration(milliseconds: 300),
                  child: _buildResetStatsCard(statsProvider),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAdReward(StatsProvider statsProvider) {
    final adService = AdService();

    if (!adService.isRewardedAdReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('광고를 준비 중입니다. 잠시 후 다시 시도해주세요.'),
          backgroundColor: Colors.orange,
        ),
      );
      adService.loadRewardedAd();
      return;
    }

    adService.showRewardedAd(
      onRewarded: () {
        statsProvider.claimAdReward();
      },
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CandyColors.ink, width: 2.5),
          ),
          child: Icon(
            icon,
            color: color == CandyColors.sun ? CandyColors.ink : Colors.white,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
        ),
      ],
    );
  }

  Widget _serviceCard({
    required Widget leading,
    required String title,
    required String description,
    required String price,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: CartoonCard(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                      color: CandyColors.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: const TextStyle(
                      color: CandyColors.inkSoft,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            ChunkyButton(
              onPressed: onPressed,
              color: CandyColors.sun,
              textColor: CandyColors.ink,
              height: 46,
              radius: 14,
              expand: false,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.monetization_on_rounded,
                    size: 18,
                    color: CandyColors.sunDeep,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    price,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconTile(Widget child, Color color) {
    return Container(
      width: 56,
      height: 56,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: child,
    );
  }

  Widget _buildTicketCard(
    ShopProvider shopProvider,
    StatsProvider statsProvider,
    ShopItem ticket,
  ) {
    return _serviceCard(
      leading: _iconTile(
        Text(ticket.ticketIcon ?? '', style: const TextStyle(fontSize: 28)),
        _tint(CandyColors.sun, 0.6),
      ),
      title: ticket.name,
      description: ticket.description,
      price: '${ticket.price}',
      onPressed: () {
        if (ticket.ticketEffect == 'change_nickname') {
          _showChangeNicknameDialog(shopProvider, ticket);
        } else {
          _showDeleteLossDialog(shopProvider, statsProvider, ticket);
        }
      },
    );
  }

  Widget _buildResetStatsCard(StatsProvider statsProvider) {
    return _serviceCard(
      leading: _iconTile(
        const Icon(Icons.refresh_rounded, color: Colors.white, size: 30),
        CandyColors.grape,
      ),
      title: '승률 초기화권',
      description: '게임 승률을 초기화합니다 (레벨 유지)',
      price: '100',
      onPressed: () => _showResetGameSelectDialog(statsProvider),
    );
  }

  void _showItemDialog(
    ShopProvider shopProvider,
    ShopItem item,
    bool hasItem,
    bool isEquipped,
  ) {
    final rc = _rarityColor(item.rarity);
    final rec = shopProvider.ownedRecord(item.id);
    // 기간제 보유 아이템은 연장 가능
    final canRenew =
        rec != null &&
        rec.expiresAt != null &&
        item.durationDays != null &&
        item.category != ShopCategory.ticket &&
        !item.isDefault;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: _sheetDeco,
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 드래그 핸들
              _sheetHandle(),
              const SizedBox(height: 20),

              // 프리뷰
              Container(
                width: 130,
                height: 130,
                decoration: BoxDecoration(
                  color: _tint(rc, 0.3),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: CandyColors.ink,
                    width: CandyTheme.outline,
                  ),
                  boxShadow: const [
                    BoxShadow(color: CandyColors.ink, offset: Offset(0, 5)),
                  ],
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: _buildItemPreview(item),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 희귀도 & 이름
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: rc,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: CandyColors.ink, width: 2.5),
                ),
                child: Text(
                  item.rarity.displayName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                item.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                item.description,
                style: const TextStyle(
                  color: CandyColors.inkSoft,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),

              if (item.durationDays != null &&
                  item.category != ShopCategory.ticket) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.timer_outlined,
                      size: 16,
                      color: CandyColors.inkSoft,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '${item.durationDays}일 동안 사용 가능',
                        style: const TextStyle(
                          color: CandyColors.inkSoft,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (rec != null && rec.expiresAt != null) ...[
                const SizedBox(height: 8),
                Text(
                  rec.isExpiringSoon
                      ? '곧 만료! · ${rec.expiresInText} (${_fmtDate(rec.expiresAt!)})'
                      : '${rec.expiresInText} · ${_fmtDate(rec.expiresAt!)}까지',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: rec.isExpiringSoon
                        ? const Color(0xFFD01E31)
                        : CandyColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ] else if (!hasItem && item.price > 0) ...[
                const SizedBox(height: 12),
                _buildDialogPrice(item),
              ],
              if (item.availableLeft != null &&
                  !item.availableLeft!.isNegative &&
                  !hasItem) ...[
                const SizedBox(height: 8),
                Text(
                  '한정 판매 · ${_leftText(item.availableLeft!)}',
                  style: const TextStyle(
                    color: CandyColors.grapeDeep,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],

              const SizedBox(height: 24),

              if (canRenew) ...[
                ChunkyButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _confirmPurchase(shopProvider, item, renewFrom: rec);
                  },
                  label: item.price == 0 ? '무료 연장' : '연장하기 · ${item.price}',
                  icon: item.price == 0 ? Icons.update : Icons.monetization_on_rounded,
                  color: CandyColors.sun,
                  textColor: CandyColors.ink,
                  height: 54,
                  radius: 16,
                  fontSize: 16,
                ),
                const SizedBox(height: 12),
              ],

              // 버튼들
              Row(
                children: [
                  Expanded(
                    child: ChunkyButton(
                      onPressed: () => Navigator.pop(context),
                      label: '닫기',
                      color: Colors.white,
                      textColor: CandyColors.ink,
                      height: 54,
                      radius: 16,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (hasItem &&
                      !isEquipped &&
                      item.category != ShopCategory.ticket)
                    Expanded(
                      child: ChunkyButton(
                        onPressed: () {
                          Navigator.pop(context);
                          shopProvider.equipItem(item.id);
                        },
                        label: '장착하기',
                        color: CandyColors.mint,
                        textColor: CandyColors.ink,
                        height: 54,
                        radius: 16,
                        fontSize: 16,
                      ),
                    ),
                  if (isEquipped)
                    Expanded(
                      child: ChunkyButton(
                        onPressed: () {
                          Navigator.pop(context);
                          shopProvider.unequipItem(item.category.name);
                        },
                        label: '장착 해제',
                        color: CandyColors.pink,
                        height: 54,
                        radius: 16,
                        fontSize: 16,
                      ),
                    ),
                  if (!hasItem && item.category != ShopCategory.ticket)
                    Expanded(
                      child: ChunkyButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _confirmPurchase(shopProvider, item);
                        },
                        label: item.price == 0
                            ? '무료 획득'
                            : (item.durationDays != null
                                  ? '${item.price} / ${item.durationDays}일 구매'
                                  : '${item.price} 구매'),
                        icon: item.price == 0
                            ? null
                            : Icons.monetization_on_rounded,
                        color: CandyColors.sun,
                        textColor: CandyColors.ink,
                        height: 54,
                        radius: 16,
                        fontSize: 16,
                      ),
                    ),
                ],
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  /// 확인 다이얼로그에 들어가는 코인 금액 알약.
  Widget _priceBox(String text) {
    return Center(child: _coinChip(text, fontSize: 16, iconSize: 20));
  }

  static String _fmtDate(DateTime d) =>
      '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';

  /// 시트 안 가격 표시: 할인이면 원가 취소선 + -N% + 실제 가격, 기간제면 '/ N일'.
  Widget _buildDialogPrice(ShopItem item) {
    final dur = item.durationDays != null && item.category != ShopCategory.ticket
        ? ' / ${item.durationDays}일'
        : '';
    final left = item.saleEndsAt?.difference(DateTime.now());
    return Column(
      children: [
        if (item.isOnSale)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${item.originalPrice}',
                style: const TextStyle(
                  color: CandyColors.inkSoft,
                  fontWeight: FontWeight.w800,
                  decoration: TextDecoration.lineThrough,
                ),
              ),
              const SizedBox(width: 8),
              _saleSticker(item),
            ],
          ),
        const SizedBox(height: 4),
        _priceBox('${item.price} 코인$dur'),
        if (item.isOnSale && left != null && !left.isNegative)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '할인 ${_leftText(left)}',
              style: const TextStyle(
                color: Color(0xFFD01E31),
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }

  void _confirmPurchase(
    ShopProvider shopProvider,
    ShopItem item, {
    UserItem? renewFrom,
  }) {
    final renew = renewFrom != null;
    DateTime? newExpiry;
    if (item.durationDays != null && item.category != ShopCategory.ticket) {
      final now = DateTime.now();
      final base = renew && renewFrom.expiresAt!.isAfter(now)
          ? renewFrom.expiresAt!
          : now;
      newExpiry = base.add(Duration(days: item.durationDays!));
      final cap = now.add(const Duration(days: 365));
      if (newExpiry.isAfter(cap)) newExpiry = cap;
    }
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          renew ? '연장 확인' : '구매 확인',
          style: const TextStyle(fontWeight: FontWeight.w900),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              renew
                  ? '${item.name}을(를) 연장할까요?'
                  : '${item.name}을(를) 구매할까요?',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (item.price > 0) ...[
              const SizedBox(height: 12),
              _buildDialogPrice(item),
            ],
            if (newExpiry != null) ...[
              const SizedBox(height: 10),
              Text(
                '${renew ? '새 만료일' : '만료일'}: ${_fmtDate(newExpiry)}',
                style: const TextStyle(
                  color: CandyColors.inkSoft,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // 새로 구매한 경우에만 구매 후 장착 질문 (연장은 스낵바 안내)
              if (!renew && item.category != ShopCategory.ticket) {
                _lastPurchasedItem = item;
              }
              shopProvider.purchaseItem(item.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: CandyColors.sun,
              foregroundColor: CandyColors.ink,
            ),
            child: Text(renew ? '연장' : '구매'),
          ),
        ],
      ),
    );
  }

  void _askEquipAfterPurchase(ShopProvider shopProvider, ShopItem item) {
    showDialog(
      context: context,
      builder: (context) => Stack(
        alignment: Alignment.center,
        children: [
          AlertDialog(
            title: const Text(
              '구매 완료! 🎉',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DuoMascot(size: 84, mood: MascotMood.cheer),
                const SizedBox(height: 8),
                Text(
                  '${item.name}을(를) 바로 장착할까요?',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('나중에'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  shopProvider.equipItem(item.id);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: CandyColors.mint,
                  foregroundColor: CandyColors.ink,
                ),
                child: const Text('장착하기'),
              ),
            ],
          ),
          const Positioned.fill(child: ConfettiBurst()),
        ],
      ),
    );
  }

  void _showDeleteLossDialog(
    ShopProvider shopProvider,
    StatsProvider statsProvider,
    ShopItem ticket,
  ) {
    final isTriple = ticket.ticketEffect == 'delete_loss_3';
    final deleteCount = isTriple ? 3 : 1;
    final gameTypes = [
      {
        'type': 'tictactoe',
        'name': '틱택토',
        'icon': Icons.grid_3x3,
        'color': const Color(0xFFFF6B9D),
      },
      {
        'type': 'infinite_tictactoe',
        'name': '무한 틱택토',
        'icon': Icons.all_inclusive,
        'color': const Color(0xFF74B9FF),
      },
      {
        'type': 'gomoku',
        'name': '오목',
        'icon': Icons.circle_outlined,
        'color': const Color(0xFF2D3436),
      },
      {
        'type': 'reaction',
        'name': '반응속도',
        'icon': Icons.flash_on,
        'color': const Color(0xFFE17055),
      },
      {
        'type': 'rps',
        'name': '가위바위보',
        'icon': Icons.front_hand,
        'color': const Color(0xFF9B59B6),
      },
      {
        'type': 'speedtap',
        'name': '스피드탭',
        'icon': Icons.touch_app,
        'color': const Color(0xFF00CEC9),
      },
      {
        'type': 'sequence',
        'name': '순서 기억',
        'icon': Icons.psychology,
        'color': const Color(0xFFE056FD),
      },
      {
        'type': 'stroop',
        'name': '스트룹',
        'icon': Icons.palette,
        'color': const Color(0xFF00CEC9),
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: _sheetDeco,
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Center(child: _sheetHandle()),
              const SizedBox(height: 20),
              _sheetTitle('$deleteCount패 삭제', '어떤 게임의 패배를 삭제할까요?'),
              const SizedBox(height: 16),
              ...gameTypes.map((game) {
                final stats = statsProvider.getStatsForGame(
                  game['type'] as String,
                );
                final losses = stats?.losses ?? 0;

                return _gameRow(
                  game: game,
                  subtitle: '패배: $losses',
                  subtitleColor: losses > 0
                      ? CandyColors.pinkDeep
                      : CandyColors.inkSoft,
                  trailing: losses > 0
                      ? null
                      : const Text(
                          '삭제 불가',
                          style: TextStyle(
                            color: CandyColors.inkSoft,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                  onTap: losses > 0
                      ? () {
                          Navigator.pop(context);
                          _confirmDeleteLoss(
                            shopProvider,
                            ticket,
                            game['type'] as String,
                            game['name'] as String,
                          );
                        }
                      : null,
                );
              }),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDeleteLoss(
    ShopProvider shopProvider,
    ShopItem ticket,
    String gameType,
    String gameName,
  ) {
    final isTriple = ticket.ticketEffect == 'delete_loss_3';
    final deleteCount = isTriple ? 3 : 1;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$gameName의 패배 $deleteCount회를 삭제할까요?'),
            const SizedBox(height: 12),
            _priceBox('${ticket.price} 코인'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              shopProvider.deleteLoss(
                gameType,
                count: deleteCount,
                price: ticket.price,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: CandyColors.sun,
              foregroundColor: CandyColors.ink,
            ),
            child: const Text('사용'),
          ),
        ],
      ),
    );
  }

  void _showChangeNicknameDialog(ShopProvider shopProvider, ShopItem ticket) {
    final controller = TextEditingController();
    final statsProvider = context.read<StatsProvider>();
    final currentCoins = statsProvider.coins;

    if (currentCoins < ticket.price) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('코인이 부족합니다. (현재: $currentCoins, 필요: ${ticket.price})'),
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('닉네임 변경'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: '새 닉네임',
                hintText: '2-20자 입력',
                filled: true,
                fillColor: Colors.white,
              ),
              maxLength: 20,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            _priceBox('${ticket.price} 코인'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              final newNickname = controller.text.trim();
              if (newNickname.length < 2) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('닉네임은 2자 이상이어야 합니다')),
                );
                return;
              }
              Navigator.pop(context);
              shopProvider.changeNickname(newNickname);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: CandyColors.sun,
              foregroundColor: CandyColors.ink,
            ),
            child: const Text('변경'),
          ),
        ],
      ),
    );
  }

  void _showResetGameSelectDialog(StatsProvider statsProvider) {
    final gameTypes = [
      {
        'type': 'tictactoe',
        'name': '틱택토',
        'icon': Icons.grid_3x3,
        'color': const Color(0xFFFF6B9D),
      },
      {
        'type': 'infinite_tictactoe',
        'name': '무한 틱택토',
        'icon': Icons.all_inclusive,
        'color': const Color(0xFF74B9FF),
      },
      {
        'type': 'gomoku',
        'name': '오목',
        'icon': Icons.circle_outlined,
        'color': const Color(0xFF2D3436),
      },
      {
        'type': 'reaction',
        'name': '반응속도',
        'icon': Icons.flash_on,
        'color': const Color(0xFFE17055),
      },
      {
        'type': 'rps',
        'name': '가위바위보',
        'icon': Icons.front_hand,
        'color': const Color(0xFF9B59B6),
      },
      {
        'type': 'speedtap',
        'name': '스피드탭',
        'icon': Icons.touch_app,
        'color': const Color(0xFF00CEC9),
      },
      {
        'type': 'sequence',
        'name': '순서 기억',
        'icon': Icons.psychology,
        'color': const Color(0xFFE056FD),
      },
      {
        'type': 'stroop',
        'name': '스트룹',
        'icon': Icons.palette,
        'color': const Color(0xFF00CEC9),
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) => Container(
          decoration: _sheetDeco,
          padding: const EdgeInsets.all(24),
          child: ListView(
            controller: scrollController,
            children: [
              Center(child: _sheetHandle()),
              const SizedBox(height: 20),
              _sheetTitle('승률 초기화', '어떤 게임의 승률을 초기화할까요?'),
              const SizedBox(height: 16),
              ...gameTypes.map(
                (game) => _gameRow(
                  game: game,
                  onTap: () {
                    Navigator.pop(context);
                    _confirmReset(
                      statsProvider,
                      game['type'] as String,
                      game['name'] as String,
                    );
                  },
                ),
              ),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmReset(
    StatsProvider statsProvider,
    String gameType,
    String gameName,
  ) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$gameName의 승률을 초기화할까요?'),
            const SizedBox(height: 12),
            _priceBox('100 코인'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              statsProvider.resetStats(gameType);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: CandyColors.sun,
              foregroundColor: CandyColors.ink,
            ),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
  }
}

class _TabInfo {
  final IconData icon;
  final String label;
  final Color color;

  _TabInfo(this.icon, this.label, this.color);
}

class _SliverTabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  final Color backgroundColor;

  _SliverTabBarDelegate(this.tabBar, this.backgroundColor);

  @override
  double get minExtent => tabBar.preferredSize.height + 16;
  @override
  double get maxExtent => tabBar.preferredSize.height + 16;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: backgroundColor,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_SliverTabBarDelegate oldDelegate) {
    return tabBar != oldDelegate.tabBar;
  }
}
