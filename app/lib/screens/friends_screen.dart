import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/friend_provider.dart';
import '../providers/auth_provider.dart';

class FriendsScreen extends StatefulWidget {
  const FriendsScreen({super.key});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  final _friendCodeController = TextEditingController();

  @override
  void dispose() {
    _friendCodeController.dispose();
    super.dispose();
  }

  void _showAddFriendDialog(BuildContext context) {
    _friendCodeController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.person_add, color: Theme.of(context).primaryColor),
            const SizedBox(width: 8),
            const Text('친구 추가'),
          ],
        ),
        content: TextField(
          controller: _friendCodeController,
          decoration: InputDecoration(
            labelText: '친구 코드',
            hintText: 'ABCD1234',
            prefixIcon: const Icon(Icons.tag),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
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
          ElevatedButton(
            onPressed: () {
              final code = _friendCodeController.text.trim();
              if (code.length == 8) {
                context.read<FriendProvider>().addFriend(code);
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).primaryColor,
              foregroundColor: Colors.white,
            ),
            child: const Text('추가'),
          ),
        ],
      ),
    );
  }

  void _showInviteGameDialog(BuildContext context, Friend friend) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.sports_esports, color: Colors.pink),
            const SizedBox(width: 8),
            Text('${friend.nickname}님 초대'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('어떤 게임으로 초대할까요?'),
            const SizedBox(height: 16),
            _buildGameOption(
              context,
              friend,
              '틱택토',
              'tictactoe',
              Icons.grid_3x3,
            ),
            const SizedBox(height: 8),
            _buildGameOption(
              context,
              friend,
              '무한 틱택토',
              'infinite_tictactoe',
              Icons.all_inclusive,
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

  Widget _buildGameOption(
    BuildContext context,
    Friend friend,
    String title,
    String gameType,
    IconData icon,
  ) {
    return InkWell(
      onTap: () {
        context.read<FriendProvider>().inviteToGame(friend.id, gameType);
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${friend.nickname}님에게 초대를 보냈습니다!')),
        );
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.pink.shade200),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.pink),
            const SizedBox(width: 12),
            Text(title, style: const TextStyle(fontSize: 16)),
            const Spacer(),
            const Icon(Icons.arrow_forward_ios, size: 16),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    // 게스트 로그인인 경우
    if (auth.userId == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.lock_outline,
                size: 64,
                color: Colors.grey.shade400,
              ),
              const SizedBox(height: 16),
              Text(
                '친구 기능을 사용하려면\n소셜 로그인이 필요합니다',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  auth.logout();
                },
                icon: const Icon(Icons.login),
                label: const Text('다시 로그인'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
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
                backgroundColor: Colors.red,
              ),
            );
            friendProvider.clearMessages();
          }
          if (friendProvider.successMessage != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(friendProvider.successMessage!),
                backgroundColor: Colors.green,
              ),
            );
            friendProvider.clearMessages();
          }
        });

        return RefreshIndicator(
          onRefresh: () async {
            friendProvider.getFriends();
            friendProvider.getInvitations();
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 내 친구 코드
                _buildMyFriendCodeCard(context, friendProvider),
                const SizedBox(height: 24),

                // 받은 초대
                if (friendProvider.invitations.isNotEmpty) ...[
                  _buildInvitationsSection(context, friendProvider),
                  const SizedBox(height: 24),
                ],

                // 친구 목록
                _buildFriendsSection(context, friendProvider),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMyFriendCodeCard(BuildContext context, FriendProvider friendProvider) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Theme.of(context).primaryColor,
              Theme.of(context).primaryColor.withValues(alpha: 0.8),
            ],
          ),
        ),
        child: Column(
          children: [
            const Text(
              '내 친구 코드',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  friendProvider.myFriendCode ?? '------',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(width: 12),
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
                      : null,
                  icon: const Icon(Icons.copy, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '친구에게 이 코드를 공유하세요',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInvitationsSection(BuildContext context, FriendProvider friendProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.mail, color: Theme.of(context).primaryColor),
            const SizedBox(width: 8),
            Text(
              '받은 초대 (${friendProvider.invitations.length})',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...friendProvider.invitations.map((invitation) => _buildInvitationCard(context, invitation, friendProvider)),
      ],
    );
  }

  Widget _buildInvitationCard(BuildContext context, Invitation invitation, FriendProvider friendProvider) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.2),
                  child: Icon(
                    Icons.person,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${invitation.inviterNickname}님의 초대',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        invitation.gameTypeName,
                        style: TextStyle(
                          color: Colors.grey.shade600,
                          fontSize: 14,
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
                  child: OutlinedButton(
                    onPressed: () {
                      friendProvider.declineInvitation(invitation.id);
                    },
                    child: const Text('거절'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      friendProvider.acceptInvitation(invitation.id);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Theme.of(context).primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('수락'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFriendsSection(BuildContext context, FriendProvider friendProvider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.people, color: Theme.of(context).primaryColor),
                const SizedBox(width: 8),
                Text(
                  '친구 목록 (${friendProvider.friends.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            IconButton(
              onPressed: () => _showAddFriendDialog(context),
              icon: Icon(Icons.person_add, color: Theme.of(context).primaryColor),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (friendProvider.friends.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.people_outline,
                    size: 64,
                    color: Colors.grey.shade300,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '아직 친구가 없어요',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => _showAddFriendDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('친구 추가하기'),
                  ),
                ],
              ),
            ),
          )
        else
          ...friendProvider.friends.map((friend) => _buildFriendCard(context, friend, friendProvider)),
      ],
    );
  }

  Widget _buildFriendCard(BuildContext context, Friend friend, FriendProvider friendProvider) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: Stack(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).primaryColor.withValues(alpha: 0.2),
              backgroundImage: friend.avatarUrl != null ? NetworkImage(friend.avatarUrl!) : null,
              child: friend.avatarUrl == null
                  ? Icon(Icons.person, color: Theme.of(context).primaryColor)
                  : null,
            ),
            if (friend.isOnline)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          friend.nickname,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          friend.isOnline ? '온라인' : '오프라인',
          style: TextStyle(
            color: friend.isOnline ? Colors.green : Colors.grey,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (friend.isOnline)
              IconButton(
                onPressed: () => _showInviteGameDialog(context, friend),
                icon: Icon(
                  Icons.sports_esports,
                  color: Theme.of(context).primaryColor,
                ),
                tooltip: '게임 초대',
              ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'remove') {
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('친구 삭제'),
                      content: Text('${friend.nickname}님을 친구 목록에서 삭제할까요?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('취소'),
                        ),
                        TextButton(
                          onPressed: () {
                            friendProvider.removeFriend(friend.id);
                            Navigator.pop(context);
                          },
                          child: const Text('삭제', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'remove',
                  child: Row(
                    children: [
                      Icon(Icons.person_remove, color: Colors.red, size: 20),
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
