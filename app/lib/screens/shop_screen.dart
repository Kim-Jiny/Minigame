import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/shop_provider.dart';
import '../providers/stats_provider.dart';
import '../models/shop_item.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

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
      appBar: AppBar(
        title: const Text('코인 샵'),
        backgroundColor: Colors.amber.shade600,
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(icon: Icon(Icons.crop_square), text: '프레임'),
            Tab(icon: Icon(Icons.badge), text: '칭호'),
            Tab(icon: Icon(Icons.palette), text: '테마'),
            Tab(icon: Icon(Icons.face), text: '아바타'),
            Tab(icon: Icon(Icons.confirmation_number), text: '티켓'),
          ],
        ),
      ),
      body: Consumer2<ShopProvider, StatsProvider>(
        builder: (context, shopProvider, statsProvider, child) {
          // 메시지 표시
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (shopProvider.error != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(shopProvider.error!), backgroundColor: Colors.red),
              );
              shopProvider.clearMessages();
            }
            if (shopProvider.successMessage != null) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(shopProvider.successMessage!), backgroundColor: Colors.green),
              );
              shopProvider.clearMessages();
              // 마일리지 새로고침
              statsProvider.getMileage();
            }
          });

          return Column(
            children: [
              // 코인 표시
              _buildCoinHeader(statsProvider),

              // 탭 컨텐츠
              Expanded(
                child: TabBarView(
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
            ],
          );
        },
      ),
    );
  }

  Widget _buildCoinHeader(StatsProvider statsProvider) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.amber.shade600, Colors.amber.shade400],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.monetization_on, color: Colors.white, size: 28),
          const SizedBox(width: 8),
          Text(
            '${statsProvider.mileage}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            '코인',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildItemGrid(ShopProvider shopProvider, ShopCategory category) {
    final items = shopProvider.getItemsByCategory(category);

    if (shopProvider.isLoading && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (items.isEmpty) {
      return const Center(child: Text('아이템이 없습니다.'));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildItemCard(shopProvider, item);
      },
    );
  }

  Widget _buildItemCard(ShopProvider shopProvider, ShopItem item) {
    final hasItem = shopProvider.hasItem(item.id);
    final isEquipped = shopProvider.isEquipped(item.id);

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isEquipped
            ? BorderSide(color: Colors.green.shade400, width: 3)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: () => _showItemDialog(shopProvider, item, hasItem, isEquipped),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 프리뷰
              Expanded(
                child: Center(
                  child: _buildItemPreview(item),
                ),
              ),

              // 희귀도 뱃지
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: item.rarity.color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
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
              const SizedBox(height: 4),

              // 이름
              Text(
                item.name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),

              // 기간/가격 정보
              Row(
                children: [
                  if (item.durationDays != null) ...[
                    Icon(Icons.timer, size: 12, color: Colors.grey.shade600),
                    const SizedBox(width: 2),
                    Text(
                      '${item.durationDays}일',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    const SizedBox(width: 8),
                  ],
                  if (hasItem)
                    Text(
                      isEquipped ? '장착 중' : '보유 중',
                      style: TextStyle(
                        fontSize: 12,
                        color: isEquipped ? Colors.green : Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else if (item.price == 0)
                    const Text(
                      '무료',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.green,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else
                    Row(
                      children: [
                        Icon(Icons.monetization_on, size: 14, color: Colors.amber.shade700),
                        const SizedBox(width: 2),
                        Text(
                          '${item.price}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.amber.shade700,
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

    if (tickets.isEmpty) {
      return const Center(child: Text('티켓이 없습니다.'));
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1패 삭제권
        ...tickets.map((ticket) => _buildTicketCard(shopProvider, statsProvider, ticket)),

        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 16),

        // 기존 승률 초기화권
        _buildResetStatsCard(statsProvider),
      ],
    );
  }

  Widget _buildTicketCard(ShopProvider shopProvider, StatsProvider statsProvider, ShopItem ticket) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.amber.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(ticket.ticketIcon ?? '', style: const TextStyle(fontSize: 24)),
        ),
        title: Text(ticket.name, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(ticket.description),
        trailing: OutlinedButton.icon(
          onPressed: () => _showDeleteLossDialog(shopProvider, statsProvider, ticket),
          icon: const Icon(Icons.monetization_on, size: 16),
          label: Text('${ticket.price}'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.amber.shade700,
          ),
        ),
      ),
    );
  }

  Widget _buildResetStatsCard(StatsProvider statsProvider) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.purple.shade100,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.refresh, color: Colors.purple.shade700),
        ),
        title: const Text('승률 초기화권', style: TextStyle(fontWeight: FontWeight.bold)),
        subtitle: const Text('게임 승률을 초기화합니다 (레벨 유지)'),
        trailing: OutlinedButton.icon(
          onPressed: () => _showResetGameSelectDialog(statsProvider),
          icon: const Icon(Icons.monetization_on, size: 16),
          label: const Text('100'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.amber.shade700,
          ),
        ),
      ),
    );
  }

  void _showItemDialog(ShopProvider shopProvider, ShopItem item, bool hasItem, bool isEquipped) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: item.rarity.color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                item.rarity.displayName,
                style: TextStyle(
                  color: item.rarity.color,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(item.name)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 프리뷰
            SizedBox(
              height: 100,
              child: _buildItemPreview(item),
            ),
            const SizedBox(height: 16),
            Text(item.description, textAlign: TextAlign.center),
            if (item.durationDays != null) ...[
              const SizedBox(height: 8),
              Text(
                '기간: ${item.durationDays}일',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
          if (hasItem && !isEquipped && item.category != ShopCategory.ticket)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                shopProvider.equipItem(item.id);
              },
              child: const Text('장착'),
            ),
          if (isEquipped)
            OutlinedButton(
              onPressed: () {
                Navigator.pop(context);
                shopProvider.unequipItem(item.category.name);
              },
              child: const Text('장착 해제'),
            ),
          if (!hasItem && item.category != ShopCategory.ticket)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _confirmPurchase(shopProvider, item);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber.shade600,
                foregroundColor: Colors.white,
              ),
              child: item.price == 0
                  ? const Text('무료 획득')
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.monetization_on, size: 16),
                        const SizedBox(width: 4),
                        Text('${item.price}'),
                      ],
                    ),
            ),
        ],
      ),
    );
  }

  void _confirmPurchase(ShopProvider shopProvider, ShopItem item) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('구매 확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${item.name}을(를) 구매할까요?'),
            const SizedBox(height: 8),
            if (item.price > 0)
              Text(
                '${item.price} 코인이 차감됩니다.',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
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
              shopProvider.purchaseItem(item.id);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('구매'),
          ),
        ],
      ),
    );
  }

  void _showDeleteLossDialog(ShopProvider shopProvider, StatsProvider statsProvider, ShopItem ticket) {
    final gameTypes = [
      {'type': 'tictactoe', 'name': '틱택토', 'icon': Icons.grid_3x3, 'color': const Color(0xFF6C5CE7)},
      {'type': 'infinite_tictactoe', 'name': '무한 틱택토', 'icon': Icons.all_inclusive, 'color': const Color(0xFF74B9FF)},
      {'type': 'gomoku', 'name': '오목', 'icon': Icons.grid_on, 'color': const Color(0xFF2D3436)},
      {'type': 'reaction', 'name': '반응속도', 'icon': Icons.flash_on, 'color': const Color(0xFFFFD93D)},
      {'type': 'rps', 'name': '가위바위보', 'icon': Icons.pan_tool, 'color': const Color(0xFFFF7675)},
      {'type': 'speedtap', 'name': '스피드탭', 'icon': Icons.touch_app, 'color': const Color(0xFF00CEC9)},
      {'type': 'sequence', 'name': '순서 기억', 'icon': Icons.psychology, 'color': const Color(0xFF6C5CE7)},
      {'type': 'stroop', 'name': '스트룹', 'icon': Icons.color_lens, 'color': const Color(0xFFE17055)},
    ];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('1패 삭제'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('어떤 게임의 패배를 삭제할까요?\n(${ticket.price} 코인 차감)'),
            const SizedBox(height: 16),
            ...gameTypes.map((game) {
              final stats = statsProvider.getStatsForGame(game['type'] as String);
              final losses = stats?.losses ?? 0;

              return ListTile(
                enabled: losses > 0,
                leading: Icon(game['icon'] as IconData, color: game['color'] as Color),
                title: Text(game['name'] as String),
                subtitle: Text('패배: $losses'),
                onTap: losses > 0
                    ? () {
                        Navigator.pop(context);
                        _confirmDeleteLoss(shopProvider, ticket, game['type'] as String, game['name'] as String);
                      }
                    : null,
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteLoss(ShopProvider shopProvider, ShopItem ticket, String gameType, String gameName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$gameName의 패배 1회를 삭제할까요?'),
            const SizedBox(height: 8),
            Text(
              '${ticket.price} 코인이 차감됩니다.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
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
              // 1패 삭제 (서버에서 코인 차감까지 처리)
              shopProvider.deleteLoss(gameType);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber.shade600,
              foregroundColor: Colors.white,
            ),
            child: const Text('사용'),
          ),
        ],
      ),
    );
  }

  void _showResetGameSelectDialog(StatsProvider statsProvider) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('승률 초기화'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('어떤 게임의 승률을 초기화할까요?'),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.grid_3x3, color: Color(0xFF6C5CE7)),
              title: const Text('틱택토'),
              onTap: () {
                Navigator.pop(context);
                _confirmReset(statsProvider, 'tictactoe', '틱택토');
              },
            ),
            ListTile(
              leading: const Icon(Icons.all_inclusive, color: Color(0xFF74B9FF)),
              title: const Text('무한 틱택토'),
              onTap: () {
                Navigator.pop(context);
                _confirmReset(statsProvider, 'infinite_tictactoe', '무한 틱택토');
              },
            ),
            ListTile(
              leading: const Icon(Icons.grid_on, color: Color(0xFF2D3436)),
              title: const Text('오목'),
              onTap: () {
                Navigator.pop(context);
                _confirmReset(statsProvider, 'gomoku', '오목');
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  void _confirmReset(StatsProvider statsProvider, String gameType, String gameName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$gameName의 승률을 초기화할까요?'),
            const SizedBox(height: 8),
            Text(
              '100 코인이 차감됩니다.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
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
              foregroundColor: Colors.white,
            ),
            child: const Text('초기화'),
          ),
        ],
      ),
    );
  }
}
