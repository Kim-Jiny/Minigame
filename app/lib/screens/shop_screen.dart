import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/shop_provider.dart';
import '../providers/stats_provider.dart';
import '../providers/auth_provider.dart';
import '../models/shop_item.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  ShopItem? _lastPurchasedItem; // 마지막 구매 시도한 아이템
  static const Color _bgTop = Color(0xFFFDF6E3);
  static const Color _bgBottom = Color(0xFFF8FAFF);
  static const Color _panel = Color(0xFFFFFFFF);
  static const Color _panelAlt = Color(0xFFF1F5FF);
  static const Color _gold = Color(0xFFF7C948);
  static const Color _goldDeep = Color(0xFFE5B13F);

  final List<_TabInfo> _tabs = [
    _TabInfo(Icons.auto_awesome, '프레임', const Color(0xFF9B59B6)),
    _TabInfo(Icons.military_tech, '칭호', const Color(0xFFE74C3C)),
    _TabInfo(Icons.palette, '테마', const Color(0xFF3498DB)),
    _TabInfo(Icons.face, '아바타', const Color(0xFF2ECC71)),
    _TabInfo(Icons.confirmation_number, '티켓', const Color(0xFFF39C12)),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgBottom,
      body: Consumer2<ShopProvider, StatsProvider>(
        builder: (context, shopProvider, statsProvider, child) {
          // 메시지 표시
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (shopProvider.error != null) {
              _lastPurchasedItem = null; // 구매 실패 시 초기화
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(shopProvider.error!), backgroundColor: Colors.red),
              );
              shopProvider.clearMessages();
            }
            if (shopProvider.successMessage != null) {
              // 구매 성공 시 장착 여부 묻기
              final purchasedItem = _lastPurchasedItem;
              if (purchasedItem != null && shopProvider.successMessage!.contains('구매')) {
                _lastPurchasedItem = null;
                shopProvider.clearMessages();
                statsProvider.getMileage();
                _askEquipAfterPurchase(shopProvider, purchasedItem);
              } else {
                if (shopProvider.lastChangedNickname != null) {
                  context.read<AuthProvider>().setNickname(shopProvider.lastChangedNickname!);
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(shopProvider.successMessage!), backgroundColor: Colors.green),
                );
                shopProvider.clearMessages();
                statsProvider.getMileage();
              }
            }
          });

          return Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_bgTop, _bgBottom],
              ),
            ),
            child: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                // 커스텀 AppBar
                SliverAppBar(
                  expandedHeight: 140,
                  floating: false,
                  pinned: true,
                  backgroundColor: _bgTop,
                  flexibleSpace: FlexibleSpaceBar(
                    background: _buildCoinHeader(statsProvider),
                  ),
                  title: innerBoxIsScrolled
                      ? const Text('코인 샵', style: TextStyle(color: Color(0xFF2D2D2D)))
                      : null,
                  iconTheme: const IconThemeData(color: Color(0xFF2D2D2D)),
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
                      labelColor: const Color(0xFF2D2D2D),
                      unselectedLabelColor: Colors.black45,
                      indicatorSize: TabBarIndicatorSize.tab,
                      dividerColor: Colors.transparent,
                      indicator: BoxDecoration(
                        borderRadius: BorderRadius.circular(25),
                        color: Colors.black.withValues(alpha: 0.08),
                      ),
                      tabs: _tabs.map((tab) => _buildTab(tab)).toList(),
                    ),
                    _bgTop,
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
                _buildTicketList(shopProvider, statsProvider),
              ],
            ),
          ),
          );
        },
      ),
    );
  }

  Widget _buildTab(_TabInfo tab) {
    return Tab(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: tab.color.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(tab.icon, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 8),
            Text(tab.label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _buildCoinHeader(StatsProvider statsProvider) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_panel, _panelAlt],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 코인 아이콘 (애니메이션 효과)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [_gold, _goldDeep],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.4),
                          blurRadius: 15,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.monetization_on, color: Color(0xFF3A2A00), size: 32),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '보유 코인',
                        style: TextStyle(color: Colors.black54, fontSize: 14),
                      ),
                      Text(
                        '${statsProvider.mileage}',
                        style: const TextStyle(
                          color: Color(0xFF2D2D2D),
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildItemGrid(ShopProvider shopProvider, ShopCategory category) {
    final items = shopProvider.getItemsByCategory(category);

    if (shopProvider.isLoading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.shopping_bag_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('아이템이 없습니다', style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    // 정렬: 보유 아이템 먼저, 그 다음 희귀도순 (커먼 → 레어 → 에픽 → 레전더리)
    final sortedItems = List<ShopItem>.from(items)
      ..sort((a, b) {
        final aOwned = shopProvider.hasItem(a.id) ? 0 : 1;
        final bOwned = shopProvider.hasItem(b.id) ? 0 : 1;
        if (aOwned != bOwned) return aOwned.compareTo(bOwned);
        // 희귀도 순 (common=0, rare=1, epic=2, legendary=3)
        return a.rarity.index.compareTo(b.rarity.index);
      });

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.74,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: sortedItems.length,
      itemBuilder: (context, index) {
        final item = sortedItems[index];
        return _buildItemCard(shopProvider, item);
      },
    );
  }

  Widget _buildItemCard(ShopProvider shopProvider, ShopItem item) {
    final hasItem = shopProvider.hasItem(item.id);
    final isEquipped = shopProvider.isEquipped(item.id);

    // 희귀도별 색상
    final rarityColors = _getRarityGradient(item.rarity);

    return GestureDetector(
      onTap: () => _showItemDialog(shopProvider, item, hasItem, isEquipped),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: isEquipped
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Colors.green.shade400, Colors.green.shade600],
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: isEquipped
                  ? Colors.green.withValues(alpha: 0.3)
                  : item.rarity.color.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Container(
          margin: isEquipped ? const EdgeInsets.all(3) : EdgeInsets.zero,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(isEquipped ? 13 : 16),
            color: _panel,
            border: Border.all(color: Colors.black.withValues(alpha: 0.06)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 상단 희귀도 바
              Container(
                height: 4,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  gradient: LinearGradient(colors: rarityColors),
                ),
              ),
              // 프리뷰 영역
              Expanded(
                flex: 3,
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _panelAlt,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Stack(
                    children: [
                      Center(child: _buildItemPreview(item)),
                      // 장착 중 뱃지
                      if (isEquipped)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.green,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.check_circle, size: 10, color: Colors.white),
                                SizedBox(width: 2),
                                Text('장착', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        ),
                      // 보유 중 뱃지
                      if (hasItem && !isEquipped)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade400,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('보유', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // 정보 영역
              Expanded(
                flex: 2,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 희귀도 뱃지
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [rarityColors[0].withValues(alpha: 0.2), rarityColors[1].withValues(alpha: 0.2)],
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          item.rarity.displayName,
                          style: TextStyle(
                            color: item.rarity.color,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 이름
                      Text(
                        item.name,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: Color(0xFF2D2D2D),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(),
                      // 가격/상태
                      _buildPriceOrStatus(item, hasItem, isEquipped),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Color> _getRarityGradient(Rarity rarity) {
    switch (rarity) {
      case Rarity.common:
        return [Colors.grey.shade400, Colors.grey.shade500];
      case Rarity.rare:
        return [Colors.blue.shade400, Colors.blue.shade600];
      case Rarity.epic:
        return [Colors.purple.shade400, Colors.purple.shade600];
      case Rarity.legendary:
        return [Colors.amber.shade400, Colors.orange.shade600];
    }
  }

  Widget _buildPriceOrStatus(ShopItem item, bool hasItem, bool isEquipped) {
    if (hasItem) {
      return const SizedBox.shrink();
    }

    if (item.price == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          '무료',
          style: TextStyle(
            color: Colors.green,
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_gold, _goldDeep],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.monetization_on, size: 14, color: Color(0xFF3A2A00)),
          const SizedBox(width: 4),
          Text(
            '${item.price}',
            style: TextStyle(
              color: const Color(0xFF3A2A00),
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
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
      case ShopCategory.ticket:
        return _buildTicketPreview(item);
    }
  }

  Widget _buildFramePreview(ShopItem item) {
    final isRainbow = item.isRainbow;
    final borderColor = item.borderColor ?? Colors.grey;

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
        border: !isRainbow
            ? Border.all(color: borderColor, width: 4)
            : null,
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
              child: const Icon(Icons.person, size: 40, color: Colors.grey),
            )
          : const Icon(Icons.person, size: 40, color: Colors.grey),
    );
  }

  Widget _buildTitlePreview(ShopItem item) {
    final textColor = item.textColor ?? Colors.grey;
    final icon = item.titleIcon;
    final gradient = item.titleGradient;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null)
          Text(icon, style: const TextStyle(fontSize: 32)),
        const SizedBox(height: 4),
        ShaderMask(
          shaderCallback: (bounds) {
            if (gradient != null && gradient.length >= 2) {
              return LinearGradient(colors: gradient).createShader(bounds);
            }
            return LinearGradient(colors: [textColor, textColor]).createShader(bounds);
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
    final colors = item.gradientColors ?? [Colors.grey, Colors.grey.shade300];

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
    final emoji = item.avatarEmoji ?? '👤';
    final bgColor = item.avatarBgColor ?? Colors.grey.shade200;

    return Container(
      width: 70,
      height: 70,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        boxShadow: [
          BoxShadow(
            color: bgColor.withValues(alpha: 0.5),
            blurRadius: 8,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Center(
        child: Text(emoji, style: const TextStyle(fontSize: 40)),
      ),
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
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildTicketList(ShopProvider shopProvider, StatsProvider statsProvider) {
    final tickets = shopProvider.getItemsByCategory(ShopCategory.ticket);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 섹션 헤더
        _buildSectionHeader('특별 티켓', Icons.local_activity, Colors.amber),
        const SizedBox(height: 12),

        // 티켓 목록
        ...tickets.map((ticket) => _buildTicketCard(shopProvider, statsProvider, ticket)),

        const SizedBox(height: 24),

        // 섹션 헤더
        _buildSectionHeader('기타 서비스', Icons.build_circle, Colors.purple),
        const SizedBox(height: 12),

        // 승률 초기화권
        _buildResetStatsCard(statsProvider),
      ],
    );
  }

  Widget _buildSectionHeader(String title, IconData icon, Color color) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.grey.shade800,
          ),
        ),
      ],
    );
  }

  Widget _buildTicketCard(ShopProvider shopProvider, StatsProvider statsProvider, ShopItem ticket) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shadowColor: Colors.amber.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // 아이콘
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.amber.shade100, Colors.amber.shade50],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(ticket.ticketIcon ?? '', style: const TextStyle(fontSize: 28)),
            ),
            const SizedBox(width: 16),
            // 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ticket.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ticket.description,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
              ),
            ),
            // 가격 버튼
            ElevatedButton(
              onPressed: () {
                if (ticket.ticketEffect == 'change_nickname') {
                  _showChangeNicknameDialog(shopProvider, ticket);
                } else {
                  _showDeleteLossDialog(shopProvider, statsProvider, ticket);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2C3E50),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.monetization_on, size: 16, color: Colors.amber),
                  const SizedBox(width: 4),
                  Text('${ticket.price}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResetStatsCard(StatsProvider statsProvider) {
    return Card(
      elevation: 2,
      shadowColor: Colors.purple.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.purple.shade100, Colors.purple.shade50],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.refresh, color: Colors.purple.shade700, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '승률 초기화권',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '게임 승률을 초기화합니다 (레벨 유지)',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                  ),
                ],
              ),
            ),
            ElevatedButton(
              onPressed: () => _showResetGameSelectDialog(statsProvider),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2C3E50),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monetization_on, size: 16, color: Colors.amber),
                  SizedBox(width: 4),
                  Text('100', style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showItemDialog(ShopProvider shopProvider, ShopItem item, bool hasItem, bool isEquipped) {
    final rarityColors = _getRarityGradient(item.rarity);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 드래그 핸들
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),

            // 프리뷰
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: item.rarity.color.withValues(alpha: 0.3),
                  width: 2,
                ),
              ),
              child: Center(child: _buildItemPreview(item)),
            ),
            const SizedBox(height: 20),

            // 희귀도 & 이름
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [rarityColors[0].withValues(alpha: 0.2), rarityColors[1].withValues(alpha: 0.2)],
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                item.rarity.displayName,
                style: TextStyle(
                  color: item.rarity.color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              item.name,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              item.description,
              style: TextStyle(color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),

            if (item.durationDays != null) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.timer_outlined, size: 16, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Text(
                    '${item.durationDays}일 동안 사용 가능',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 24),

            // 버튼들
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('닫기'),
                  ),
                ),
                const SizedBox(width: 12),
                if (hasItem && !isEquipped && item.category != ShopCategory.ticket)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        shopProvider.equipItem(item.id);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2C3E50),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('장착하기'),
                    ),
                  ),
                if (isEquipped)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        shopProvider.unequipItem(item.category.name);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('장착 해제'),
                    ),
                  ),
                if (!hasItem && item.category != ShopCategory.ticket)
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _confirmPurchase(shopProvider, item);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber.shade600,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: item.price == 0
                          ? const Text('무료 획득')
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.monetization_on, size: 18),
                                const SizedBox(width: 6),
                                Text('${item.price} 구매'),
                              ],
                            ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
    );
  }

  void _confirmPurchase(ShopProvider shopProvider, ShopItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('구매 확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${item.name}을(를) 구매할까요?'),
            if (item.price > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.monetization_on, color: Colors.amber.shade700),
                    const SizedBox(width: 8),
                    Text(
                      '${item.price} 코인',
                      style: TextStyle(
                        color: Colors.amber.shade800,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
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
              // 티켓이 아닌 경우 구매 후 장착 질문을 위해 아이템 저장
              if (item.category != ShopCategory.ticket) {
                _lastPurchasedItem = item;
              }
              shopProvider.purchaseItem(item.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade600,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('구매'),
          ),
        ],
      ),
    );
  }

  void _askEquipAfterPurchase(ShopProvider shopProvider, ShopItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('구매 완료! 🎉'),
        content: Text('${item.name}을(를) 바로 장착할까요?'),
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
              backgroundColor: const Color(0xFF2C3E50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('장착하기'),
          ),
        ],
      ),
    );
  }

  void _showDeleteLossDialog(ShopProvider shopProvider, StatsProvider statsProvider, ShopItem ticket) {
    final gameTypes = [
      {'type': 'tictactoe', 'name': '틱택토', 'icon': Icons.grid_3x3, 'color': const Color(0xFF6C5CE7)},
      {'type': 'infinite_tictactoe', 'name': '무한 틱택토', 'icon': Icons.all_inclusive, 'color': const Color(0xFF74B9FF)},
      {'type': 'gomoku', 'name': '오목', 'icon': Icons.circle_outlined, 'color': const Color(0xFF2D3436)},
      {'type': 'reaction', 'name': '반응속도', 'icon': Icons.flash_on, 'color': const Color(0xFFE17055)},
      {'type': 'rps', 'name': '가위바위보', 'icon': Icons.front_hand, 'color': const Color(0xFF9B59B6)},
      {'type': 'speedtap', 'name': '스피드탭', 'icon': Icons.touch_app, 'color': const Color(0xFF00CEC9)},
      {'type': 'sequence', 'name': '순서 기억', 'icon': Icons.psychology, 'color': const Color(0xFFE056FD)},
      {'type': 'stroop', 'name': '스트룹', 'icon': Icons.palette, 'color': const Color(0xFF00CEC9)},
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '1패 삭제',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '어떤 게임의 패배를 삭제할까요?',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            ...gameTypes.map((game) {
              final stats = statsProvider.getStatsForGame(game['type'] as String);
              final losses = stats?.losses ?? 0;

              return ListTile(
                enabled: losses > 0,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                leading: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: (game['color'] as Color).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(game['icon'] as IconData, color: game['color'] as Color),
                ),
                title: Text(game['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('패배: $losses', style: TextStyle(color: losses > 0 ? Colors.red : Colors.grey)),
                trailing: losses > 0
                    ? const Icon(Icons.chevron_right)
                    : Text('삭제 불가', style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                onTap: losses > 0
                    ? () {
                        Navigator.pop(context);
                        _confirmDeleteLoss(shopProvider, ticket, game['type'] as String, game['name'] as String);
                      }
                    : null,
              );
            }),
            SizedBox(height: MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteLoss(ShopProvider shopProvider, ShopItem ticket, String gameType, String gameName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$gameName의 패배 1회를 삭제할까요?'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monetization_on, color: Colors.amber.shade700),
                  const SizedBox(width: 8),
                  Text(
                    '${ticket.price} 코인',
                    style: TextStyle(
                      color: Colors.amber.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
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
              shopProvider.deleteLoss(gameType);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade600,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
        SnackBar(content: Text('코인이 부족합니다. (현재: $currentCoins, 필요: ${ticket.price})')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('닉네임 변경'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(
                labelText: '새 닉네임',
                hintText: '2-20자 입력',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              maxLength: 20,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monetization_on, color: Colors.amber.shade700),
                  const SizedBox(width: 8),
                  Text(
                    '${ticket.price} 코인',
                    style: TextStyle(
                      color: Colors.amber.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
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
              backgroundColor: Colors.amber.shade600,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('변경'),
          ),
        ],
      ),
    );
  }

  void _showResetGameSelectDialog(StatsProvider statsProvider) {
    final gameTypes = [
      {'type': 'tictactoe', 'name': '틱택토', 'icon': Icons.grid_3x3, 'color': const Color(0xFF6C5CE7)},
      {'type': 'infinite_tictactoe', 'name': '무한 틱택토', 'icon': Icons.all_inclusive, 'color': const Color(0xFF74B9FF)},
      {'type': 'gomoku', 'name': '오목', 'icon': Icons.circle_outlined, 'color': const Color(0xFF2D3436)},
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '승률 초기화',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '어떤 게임의 승률을 초기화할까요?',
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 16),
            ...gameTypes.map((game) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (game['color'] as Color).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(game['icon'] as IconData, color: game['color'] as Color),
                  ),
                  title: Text(game['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(context);
                    _confirmReset(statsProvider, game['type'] as String, game['name'] as String);
                  },
                )),
            SizedBox(height: MediaQuery.of(context).padding.bottom),
          ],
        ),
      ),
    );
  }

  void _confirmReset(StatsProvider statsProvider, String gameType, String gameName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$gameName의 승률을 초기화할까요?'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.monetization_on, color: Colors.amber.shade700),
                  const SizedBox(width: 8),
                  Text(
                    '100 코인',
                    style: TextStyle(
                      color: Colors.amber.shade800,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
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
              backgroundColor: Colors.amber.shade600,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
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
