import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../providers/friend_provider.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';

class Message {
  final int id;
  final int senderId;
  final String senderNickname;
  final int receiverId;
  final String content;
  final bool isRead;
  final DateTime createdAt;
  final bool isMine;

  Message({
    required this.id,
    required this.senderId,
    required this.senderNickname,
    required this.receiverId,
    required this.content,
    required this.isRead,
    required this.createdAt,
    required this.isMine,
  });

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'],
      senderId: json['senderId'],
      senderNickname: json['senderNickname'] ?? '',
      receiverId: json['receiverId'],
      content: json['content'],
      isRead: json['isRead'] ?? false,
      createdAt: DateTime.parse(json['createdAt']),
      isMine: json['isMine'] ?? false,
    );
  }
}

class ChatScreen extends StatefulWidget {
  final Friend friend;

  const ChatScreen({super.key, required this.friend});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(
    _socketService,
  );
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Message> _messages = [];
  bool _isLoading = true;

  late final FriendProvider _friendProvider;

  @override
  void initState() {
    super.initState();
    _friendProvider = context.read<FriendProvider>(); // dispose 에서 context 를 쓰지 않기 위해 미리 보관
    _setupSocketListeners();
    if (_socketService.isReady) {
      _loadMessages();
    }
    // 채팅 화면 진입 시 읽음 처리
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final friendProvider = context.read<FriendProvider>();
      friendProvider.setActiveChatFriend(widget.friend.id);
      friendProvider.markMessagesRead(widget.friend.id);
    });
  }

  void _setupSocketListeners() {
    _socketListeners.on('lobby_joined', (_) {
      _loadMessages();
    });

    _socketListeners.on('messages_list', (data) {
      if (data['friendId'] == widget.friend.id) {
        final incomingMessages = (data['messages'] as List)
            .map((m) => Message.fromJson(m))
            .toList();
        setState(() {
          _mergeMessages(incomingMessages);
          _isLoading = false;
        });
        _scrollToBottom();
      }
    });

    _socketListeners.on('send_message_result', (data) {
      if (data['success'] == true && data['message'] != null) {
        final msg = Message.fromJson(data['message']);
        if (msg.receiverId == widget.friend.id) {
          setState(() {
            _appendMessage(msg);
          });
          _scrollToBottom();
        }
      }
    });

    _socketListeners.on('new_message', (data) {
      if (data['message'] != null) {
        final msg = Message.fromJson(data['message']);
        if (msg.senderId == widget.friend.id) {
          setState(() {
            _appendMessage(msg);
          });
          _scrollToBottom();
          // 읽음 처리 (FriendProvider를 통해 상태 동기화)
          if (mounted) {
            context.read<FriendProvider>().markMessagesRead(widget.friend.id);
          }
        }
      }
    });
  }

  void _loadMessages() {
    _socketService.emit('get_messages', {'friendId': widget.friend.id});
  }

  void _mergeMessages(List<Message> incomingMessages) {
    final messagesById = <int, Message>{
      for (final message in _messages) message.id: message,
      for (final message in incomingMessages) message.id: message,
    };

    _messages
      ..clear()
      ..addAll(
        messagesById.values.toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
      );
  }

  void _appendMessage(Message message) {
    if (_messages.any((existing) => existing.id == message.id)) {
      return;
    }
    _messages.add(message);
    _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    _socketService.emit('send_message', {
      'friendId': widget.friend.id,
      'content': content,
    });
    _messageController.clear();
  }

  @override
  void dispose() {
    _friendProvider.setActiveChatFriend(null);
    _socketListeners.offAll();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _avatar(double radius, double iconSize) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: CandyColors.ink, width: 2),
      ),
      child: CircleAvatar(
        radius: radius,
        backgroundColor: CandyColors.cream,
        backgroundImage: widget.friend.avatarUrl != null
            ? NetworkImage(widget.friend.avatarUrl!)
            : null,
        child: widget.friend.avatarUrl == null
            ? Icon(Icons.person, size: iconSize, color: CandyColors.inkSoft)
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            _avatar(15, 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.friend.memo != null && widget.friend.memo!.isNotEmpty
                        ? '${widget.friend.nickname} (${widget.friend.memo})'
                        : widget.friend.nickname,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.friend.isOnline)
                    const Text(
                      '온라인',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: FloatingBackground(
        child: Column(
          children: [
            // 안내 메시지
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: const BoxDecoration(
                color: CandyColors.sun,
                border: Border(
                  bottom: BorderSide(color: CandyColors.ink, width: 2),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: CandyColors.ink),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '메시지는 7일간 보관됩니다',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: CandyColors.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 메시지 목록
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(color: CandyColors.pink),
                    )
                  : _messages.isEmpty
                  ? _buildEmptyState()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        return _buildMessageBubble(_messages[index]);
                      },
                    ),
            ),

            // 입력창
            _buildInputArea(),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const DuoMascot(size: 100, mood: MascotMood.wink),
            const SizedBox(height: 14),
            Text(
              '${widget.friend.nickname}님과의 대화를 시작해보세요!',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: CandyColors.ink,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              '첫 인사를 건네볼까요?',
              style: TextStyle(
                color: CandyColors.inkSoft,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(Message message) {
    final isMine = message.isMine;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[_avatar(14, 14), const SizedBox(width: 8)],
          Flexible(
            child: Column(
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.68,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: isMine ? CandyColors.pink : Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(18),
                      topRight: const Radius.circular(18),
                      bottomLeft: Radius.circular(isMine ? 18 : 4),
                      bottomRight: Radius.circular(isMine ? 4 : 18),
                    ),
                    border: Border.all(color: CandyColors.ink, width: 2.5),
                    boxShadow: const [
                      BoxShadow(color: CandyColors.ink, offset: Offset(0, 3)),
                    ],
                  ),
                  child: Text(
                    message.content,
                    style: TextStyle(
                      color: isMine ? Colors.white : CandyColors.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _formatTime(message.createdAt),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: CandyColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          if (isMine) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: CandyColors.ink, width: CandyTheme.outline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: '메시지를 입력하세요',
                filled: true,
                fillColor: CandyColors.cream,
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(
                    color: CandyColors.ink,
                    width: 2.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(
                    color: CandyColors.ink,
                    width: 2.5,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(
                    color: CandyColors.pink,
                    width: 3,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              minLines: 1,
              maxLines: 4,
              maxLength: 500,
              buildCounter:
                  (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 56,
            child: ChunkyButton(
              onPressed: _sendMessage,
              height: 48,
              radius: 24,
              expand: false,
              child: const Icon(
                Icons.send_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime dateTime) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate = DateTime(dateTime.year, dateTime.month, dateTime.day);

    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');

    if (messageDate == today) {
      return '$hour:$minute';
    } else if (today.difference(messageDate).inDays == 1) {
      return '어제 $hour:$minute';
    } else {
      return '${dateTime.month}/${dateTime.day} $hour:$minute';
    }
  }
}
