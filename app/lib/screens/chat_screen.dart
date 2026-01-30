import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/socket_service.dart';
import '../providers/friend_provider.dart';

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
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Message> _messages = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _setupSocketListeners();
    _loadMessages();
    // 채팅 화면 진입 시 읽음 처리
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<FriendProvider>().markMessagesRead(widget.friend.id);
    });
  }

  void _setupSocketListeners() {
    _socketService.on('messages_list', (data) {
      if (data['friendId'] == widget.friend.id) {
        setState(() {
          _messages.clear();
          _messages.addAll(
            (data['messages'] as List).map((m) => Message.fromJson(m)).toList(),
          );
          _isLoading = false;
        });
        _scrollToBottom();
      }
    });

    _socketService.on('send_message_result', (data) {
      if (data['success'] == true && data['message'] != null) {
        final msg = Message.fromJson(data['message']);
        if (msg.receiverId == widget.friend.id) {
          setState(() {
            _messages.add(msg);
          });
          _scrollToBottom();
        }
      }
    });

    _socketService.on('new_message', (data) {
      if (data['message'] != null) {
        final msg = Message.fromJson(data['message']);
        if (msg.senderId == widget.friend.id) {
          setState(() {
            _messages.add(msg);
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
    _socketService.off('messages_list');
    _socketService.off('send_message_result');
    _socketService.off('new_message');
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              backgroundImage: widget.friend.avatarUrl != null
                  ? NetworkImage(widget.friend.avatarUrl!)
                  : null,
              child: widget.friend.avatarUrl == null
                  ? const Icon(Icons.person, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.friend.memo != null && widget.friend.memo!.isNotEmpty
                        ? '${widget.friend.nickname} (${widget.friend.memo})'
                        : widget.friend.nickname,
                    style: const TextStyle(fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (widget.friend.isOnline)
                    const Text(
                      '온라인',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                ],
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // 안내 메시지
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.amber.shade50,
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.amber.shade700),
                const SizedBox(width: 8),
                Text(
                  '메시지는 7일간 보관됩니다',
                  style: TextStyle(fontSize: 12, color: Colors.amber.shade700),
                ),
              ],
            ),
          ),

          // 메시지 목록
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
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
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '${widget.friend.nickname}님과의 대화를 시작해보세요!',
            style: TextStyle(color: Colors.grey.shade500),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(Message message) {
    final isMine = message.isMine;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMine) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: Colors.grey.shade200,
              backgroundImage: widget.friend.avatarUrl != null
                  ? NetworkImage(widget.friend.avatarUrl!)
                  : null,
              child: widget.friend.avatarUrl == null
                  ? const Icon(Icons.person, size: 14, color: Colors.grey)
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Column(
            crossAxisAlignment: isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.65,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMine ? Theme.of(context).primaryColor : Colors.grey.shade200,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMine ? 16 : 4),
                    bottomRight: Radius.circular(isMine ? 4 : 16),
                  ),
                ),
                child: Text(
                  message.content,
                  style: TextStyle(
                    color: isMine ? Colors.white : Colors.black87,
                    fontSize: 15,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _formatTime(message.createdAt),
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
          if (isMine) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            offset: const Offset(0, -1),
            blurRadius: 4,
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: InputDecoration(
                hintText: '메시지를 입력하세요',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey.shade100,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              maxLines: null,
              maxLength: 500,
              buildCounter: (context, {required currentLength, required isFocused, maxLength}) => null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _sendMessage,
            icon: Icon(Icons.send, color: Theme.of(context).primaryColor),
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
