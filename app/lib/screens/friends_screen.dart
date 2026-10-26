import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/friend_provider.dart';
import '../providers/auth_provider.dart';
import '../models/shop_item.dart';
import '../services/socket_service.dart';
import 'chat_screen.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/avatar_art.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _friendCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // 첫 진입에서 아직 친구 데이터가 없을 때만 조회한다.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final auth = context.read<AuthProvider>();
      if (auth.userId == null) return;
      final friendProvider = context.read<FriendProvider>();
      if (SocketService().isReady && !friendProvider.hasFetchedInitialData) {
        friendProvider.refreshAll();
      }
    });
  }

  @override
  void dispose() {
    _friendCodeController.dispose();
    super.dispose();
  }

  Widget _buildTitleBadge(UserProfileSettings settings) {
    final gradientColors = settings.getTitleGradient();
    final hasGradient = gradientColors != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        gradient: hasGradient
            ? LinearGradient(colors: [gradientColors.$1, gradientColors.$2])
            : null,
        color: hasGradient ? null : CandyColors.creamDeep,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CandyColors.ink, width: 1.5),
      ),
      child: Text(
        settings.activeTitleName ?? '',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          color: hasGradient ? Colors.white : CandyColors.ink,
        ),
      ),
    );
  }

  void _showAddFriendDialog(BuildContext context) {
    _friendCodeController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.person_add, color: CandyColors.pink),
            const SizedBox(width: 8),
            const Text('친구 요청', style: TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        content: TextField(
          controller: _friendCodeController,
          decoration: InputDecoration(
            labelText: '친구 코드',
            hintText: 'ABCD1234',
            prefixIcon: const Icon(Icons.tag),
            suffixIcon: IconButton(
              icon: const Icon(Icons.paste),
              tooltip: '붙여넣기',
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                if (data?.text != null) {
                  final text = data!.text!.trim().toUpperCase();
                  if (text.length <= 8) {
                    _friendCodeController.text = text;
                    _friendCodeController.selection =
                        TextSelection.fromPosition(
                          TextPosition(offset: text.length),
                        );
                  }
                }
              },
            ),
          ),
          textCapitalization: TextCapitalization.characters,
          maxLength: 8,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ChunkyButton(
            onPressed: () {
              final code = _friendCodeController.text.trim();
              if (code.length == 8) {
                context.read<FriendProvider>().sendFriendRequest(code);
                Navigator.pop(context);
              }
            },
            height: 44,
            fontSize: 15,
            expand: false,
            label: '요청 보내기',
          ),
        ],
      ),
    );
  }

  void _showEditMemoDialog(
    BuildContext context,
    Friend friend,
    FriendProvider friendProvider,
  ) {
    final controller = TextEditingController(text: friend.memo ?? '');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.edit_note, color: CandyColors.pink),
            const SizedBox(width: 8),
            const Text('메모 수정', style: TextStyle(fontWeight: FontWeight.w900)),
          ],
        ),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: '메모 (최대 20자)',
            hintText: '친구를 구분할 메모',
            prefixIcon: const Icon(Icons.note),
          ),
          maxLength: 20,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ChunkyButton(
            onPressed: () {
              friendProvider.updateFriendMemo(
                friend.id,
                controller.text.trim(),
              );
              Navigator.pop(context);
            },
            height: 44,
            fontSize: 15,
            expand: false,
            label: '저장',
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // 게스트 로그인인 경우
    if (auth.userId == null) {
      return FloatingBackground(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DuoMascot(size: 110, mood: MascotMood.sad),
                const SizedBox(height: 16),
                const Text(
                  '친구 기능을 사용하려면\n소셜 로그인이 필요해요',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: CandyColors.ink,
                  ),
                ),
                const SizedBox(height: 24),
                ChunkyButton(
                  onPressed: () {
                    auth.logout();
                  },
                  icon: Icons.login,
                  label: '다시 로그인',
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Consumer<FriendProvider>(
      builder: (context, friendProvider, child) {
        // 에러/성공 메시지 표시
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (friendProvider.error != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(friendProvider.error!),
                backgroundColor: CandyColors.pinkDeep,
              ),
            );
            friendProvider.clearMessages();
          }
          if (friendProvider.successMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(friendProvider.successMessage!),
                backgroundColor: CandyColors.mintDeep,
              ),
            );
            friendProvider.clearMessages();
          }
        });

        return FloatingBackground(
          child: RefreshIndicator(
            color: CandyColors.pink,
            onRefresh: () async {
              friendProvider.refreshAll();
            },
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final maxContentWidth = width >= 1300
                    ? 1080.0
                    : double.infinity;
                final horizontalPadding = width >= 900 ? 24.0 : 16.0;

                return Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxContentWidth),
                    child: SingleChildScrollView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.fromLTRB(
                        horizontalPadding,
                        16,
                        horizontalPadding,
                        100,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PopIn(
                            child: _buildMyFriendCodeCard(
                              context,
                              friendProvider,
                            ),
                          ),
                          const SizedBox(height: 24),
                          if (friendProvider.invitations.isNotEmpty) ...[
                            _buildInvitationsSection(context, friendProvider),
                            const SizedBox(height: 24),
                          ],
                          if (friendProvider.receivedRequests.isNotEmpty) ...[
                            _buildFriendRequestsSection(
                              context,
                              friendProvider,
                            ),
                            const SizedBox(height: 24),
                          ],
                          if (friendProvider.sentRequests.isNotEmpty) ...[
                            _buildSentRequestsSection(context, friendProvider),
                            const SizedBox(height: 24),
                          ],
                          _buildFriendsSection(context, friendProvider),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _sectionHeader(
    IconData icon,
    Color color,
    String text, {
    Widget? trailing,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: CandyColors.ink, width: 2.5),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: CandyColors.ink,
            ),
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _personAvatar(Color color) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: CandyColors.ink, width: 2.5),
      ),
      child: const Icon(Icons.person, color: Colors.white),
    );
  }

  Widget _buildMyFriendCodeCard(
    BuildContext context,
    FriendProvider friendProvider,
  ) {
    // 코드가 비어 있으면 다시 요청(로그인 직후 응답을 놓친 경우 등).
    if (friendProvider.myFriendCode == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) friendProvider.ensureFriendCode();
      });
    }
    return CartoonCard(
      color: CandyColors.sun,
      padding: const EdgeInsets.all(18),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          children: [
            const Text(
              '내 친구 코드',
              style: TextStyle(
                color: CandyColors.ink,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.only(left: 16, right: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        friendProvider.myFriendCode ?? '------',
                        style: const TextStyle(
                          color: CandyColors.ink,
                          fontSize: 32,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 4,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: friendProvider.myFriendCode != null
                        ? () {
                            Clipboard.setData(
                              ClipboardData(text: friendProvider.myFriendCode!),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('친구 코드가 복사되었습니다!')),
                            );
                          }
                        : friendProvider.getMyFriendCode,
                    icon: Icon(
                      friendProvider.myFriendCode != null
                          ? Icons.copy_rounded
                          : Icons.refresh_rounded,
                      color: CandyColors.pinkDeep,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '친구에게 이 코드를 공유하세요',
              style: TextStyle(
                color: CandyColors.ink,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _staggered(int i, Widget child) => PopIn(
    delay: Duration(milliseconds: math.min(i, 8) * 50),
    child: child,
  );

  Widget _buildInvitationsSection(
    BuildContext context,
    FriendProvider friendProvider,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          Icons.mail,
          CandyColors.pink,
          '받은 초대 (${friendProvider.invitations.length})',
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < friendProvider.invitations.length; i++)
          _staggered(
            i,
            _buildInvitationCard(
              context,
              friendProvider.invitations[i],
              friendProvider,
            ),
          ),
      ],
    );
  }

  Widget _requestCard({
    required Color avatarColor,
    required String title,
    required String subtitle,
    required VoidCallback onDecline,
    required VoidCallback onAccept,
    required Color acceptColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CartoonCard(
        shadow: 4,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _personAvatar(avatarColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                          color: CandyColors.ink,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CandyColors.inkSoft,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ChunkyButton(
                    onPressed: onDecline,
                    label: '거절',
                    color: Colors.white,
                    textColor: CandyColors.ink,
                    height: 44,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ChunkyButton(
                    onPressed: onAccept,
                    label: '수락',
                    color: acceptColor,
                    height: 44,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInvitationCard(
    BuildContext context,
    Invitation invitation,
    FriendProvider friendProvider,
  ) {
    return _requestCard(
      avatarColor: CandyColors.pink,
      title: '${invitation.inviterNickname}님의 초대',
      subtitle: invitation.gameTypeName,
      acceptColor: CandyColors.pink,
      onDecline: () {
        friendProvider.declineInvitation(invitation.id);
      },
      onAccept: () {
        friendProvider.acceptInvitation(invitation.id);
      },
    );
  }

  Widget _buildFriendRequestsSection(
    BuildContext context,
    FriendProvider friendProvider,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          Icons.person_add,
          CandyColors.mint,
          '받은 친구 요청 (${friendProvider.receivedRequests.length})',
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < friendProvider.receivedRequests.length; i++)
          _staggered(
            i,
            _buildFriendRequestCard(
              context,
              friendProvider.receivedRequests[i],
              friendProvider,
            ),
          ),
      ],
    );
  }

  Widget _buildFriendRequestCard(
    BuildContext context,
    FriendRequest request,
    FriendProvider friendProvider,
  ) {
    return _requestCard(
      avatarColor: CandyColors.mint,
      title: request.fromNickname,
      subtitle: '친구 요청을 보냈어요',
      acceptColor: CandyColors.mint,
      onDecline: () {
        friendProvider.declineFriendRequest(request.id);
      },
      onAccept: () {
        friendProvider.acceptFriendRequest(request.id);
      },
    );
  }

  Widget _buildSentRequestsSection(
    BuildContext context,
    FriendProvider friendProvider,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          Icons.send,
          CandyColors.tangerine,
          '보낸 친구 요청 (${friendProvider.sentRequests.length})',
        ),
        const SizedBox(height: 12),
        for (int i = 0; i < friendProvider.sentRequests.length; i++)
          _staggered(
            i,
            _buildSentRequestCard(
              context,
              friendProvider.sentRequests[i],
              friendProvider,
            ),
          ),
      ],
    );
  }

  Widget _buildSentRequestCard(
    BuildContext context,
    FriendRequest request,
    FriendProvider friendProvider,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CartoonCard(
        shadow: 4,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _personAvatar(CandyColors.tangerine),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    request.toNickname,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: CandyColors.ink,
                    ),
                  ),
                  const Text(
                    '요청 대기 중...',
                    style: TextStyle(
                      color: CandyColors.inkSoft,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () {
                friendProvider.cancelFriendRequest(request.id);
              },
              child: const Text(
                '취소',
                style: TextStyle(
                  color: CandyColors.pinkDeep,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFriendsSection(
    BuildContext context,
    FriendProvider friendProvider,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          Icons.people,
          CandyColors.sky,
          '친구 목록 (${friendProvider.friends.length})',
          trailing: IconButton(
            onPressed: () => _showAddFriendDialog(context),
            tooltip: '친구 추가',
            icon: const Icon(Icons.person_add, color: CandyColors.pinkDeep),
          ),
        ),
        const SizedBox(height: 12),
        if (friendProvider.friends.isEmpty)
          PopIn(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: Column(
                  children: [
                    const DuoMascot(size: 100, mood: MascotMood.sad),
                    const SizedBox(height: 14),
                    const Text(
                      '아직 친구가 없어요',
                      style: TextStyle(
                        color: CandyColors.ink,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '친구 코드로 같이 놀 친구를 찾아보세요!',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: CandyColors.inkSoft,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ChunkyButton(
                      onPressed: () => _showAddFriendDialog(context),
                      icon: Icons.add,
                      label: '친구 추가하기',
                      height: 48,
                      fontSize: 16,
                      expand: false,
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          for (int i = 0; i < friendProvider.friends.length; i++)
            _staggered(
              i,
              _buildFriendCard(
                context,
                friendProvider.friends[i],
                friendProvider,
              ),
            ),
      ],
    );
  }

  Widget _buildFriendCard(
    BuildContext context,
    Friend friend,
    FriendProvider friendProvider,
  ) {
    // 프레임 색상 가져오기
    final frameColors = friend.profileSettings?.getFrameColors();
    final isRainbow = friend.profileSettings?.isRainbowFrame() ?? false;
    final hasFrame = frameColors != null || isRainbow;
    // 아바타 정보 가져오기
    final avatarArt = friend.profileSettings?.getAvatarArt();
    final isRemoving = friendProvider.isRemoving(friend.id);
    final unread = friendProvider.unreadCounts[friend.id] ?? 0;

    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: hasFrame ? const EdgeInsets.all(3) : EdgeInsets.zero,
          decoration: hasFrame
              ? BoxDecoration(
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
                      : LinearGradient(
                          colors: [frameColors!.$1, frameColors.$2],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                  border: Border.all(color: CandyColors.ink, width: 2.5),
                )
              : BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: CandyColors.ink, width: 2.5),
                ),
          child: avatarArt != null
              ? AvatarArt(
                  itemKey: avatarArt.key,
                  emoji: avatarArt.emoji,
                  bgColor: avatarArt.bg,
                  size: 44,
                  outline: false,
                )
              : CircleAvatar(
                  radius: 22,
                  backgroundColor: CandyColors.pink.withValues(alpha: 0.25),
                  child: const Icon(Icons.person, color: CandyColors.pink),
                ),
        ),
        if (friend.isOnline)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: CandyColors.mint,
                shape: BoxShape.circle,
                border: Border.all(color: CandyColors.ink, width: 2.5),
              ),
            ),
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: CartoonCard(
        shadow: 4,
        radius: 18,
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          children: [
            avatar,
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          friend.nickname,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: CandyColors.ink,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (friend.memo != null && friend.memo!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '(${friend.memo})',
                            style: const TextStyle(
                              color: CandyColors.inkSoft,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 6,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 칭호 표시
                      if (friend.profileSettings?.activeTitleName != null)
                        _buildTitleBadge(friend.profileSettings!),
                      Text(
                        friend.isOnline ? '온라인' : '오프라인',
                        style: TextStyle(
                          color: friend.isOnline
                              ? CandyColors.mintDeep
                              : CandyColors.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // 메시지 버튼
            Stack(
              children: [
                IconButton(
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatScreen(friend: friend),
                      ),
                    );
                    friendProvider.getUnreadCounts();
                  },
                  icon: const Icon(
                    Icons.chat_bubble_rounded,
                    color: CandyColors.skyDeep,
                  ),
                  tooltip: '메시지',
                ),
                if (unread > 0)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: CandyColors.pink,
                        shape: BoxShape.circle,
                        border: Border.all(color: CandyColors.ink, width: 2),
                      ),
                      constraints: const BoxConstraints(
                        minWidth: 20,
                        minHeight: 20,
                      ),
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            if (isRemoving)
              const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: CandyColors.pink,
                  ),
                ),
              )
            else
              PopupMenuButton<String>(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                  side: const BorderSide(color: CandyColors.ink, width: 2.5),
                ),
                onSelected: (value) {
                  if (value == 'memo') {
                    _showEditMemoDialog(context, friend, friendProvider);
                  } else if (value == 'remove') {
                    showDialog(
                      context: context,
                      builder: (context) => Consumer<FriendProvider>(
                        builder: (context, provider, _) {
                          final isRemoving = provider.isRemoving(friend.id);
                          return AlertDialog(
                            title: const Text('친구 삭제'),
                            content: Text(
                              '${friend.nickname}님을 친구 목록에서 삭제할까요?',
                            ),
                            actions: [
                              TextButton(
                                onPressed: isRemoving
                                    ? null
                                    : () => Navigator.pop(context),
                                child: const Text('취소'),
                              ),
                              TextButton(
                                onPressed: isRemoving
                                    ? null
                                    : () {
                                        provider.removeFriend(friend.id);
                                        Navigator.pop(context);
                                      },
                                child: isRemoving
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Text(
                                        '삭제',
                                        style: TextStyle(
                                          color: CandyColors.pinkDeep,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'memo',
                    child: Row(
                      children: [
                        Icon(Icons.edit_note, size: 20),
                        SizedBox(width: 8),
                        Text('메모 수정'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        Icon(
                          Icons.person_remove,
                          color: CandyColors.pinkDeep,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text('친구 삭제'),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
