import 'package:flutter/foundation.dart';
import '../services/socket_service.dart';

class Friend {
  final int id;
  final String nickname;
  final String? email;
  final String? avatarUrl;
  final String? friendCode;
  final String? memo;
  final bool isOnline;

  Friend({
    required this.id,
    required this.nickname,
    this.email,
    this.avatarUrl,
    this.friendCode,
    this.memo,
    this.isOnline = false,
  });

  Friend copyWith({String? memo}) {
    return Friend(
      id: id,
      nickname: nickname,
      email: email,
      avatarUrl: avatarUrl,
      friendCode: friendCode,
      memo: memo ?? this.memo,
      isOnline: isOnline,
    );
  }

  factory Friend.fromJson(Map<String, dynamic> json) {
    return Friend(
      id: json['id'],
      nickname: json['nickname'],
      email: json['email'],
      avatarUrl: json['avatarUrl'],
      friendCode: json['friendCode'],
      memo: json['memo'],
      isOnline: json['isOnline'] ?? false,
    );
  }
}

class Invitation {
  final int id;
  final int inviterId;
  final String inviterNickname;
  final int inviteeId;
  final String inviteeNickname;
  final String gameType;
  final String status;
  final String? roomId;
  final DateTime createdAt;

  Invitation({
    required this.id,
    required this.inviterId,
    required this.inviterNickname,
    required this.inviteeId,
    required this.inviteeNickname,
    required this.gameType,
    required this.status,
    this.roomId,
    required this.createdAt,
  });

  factory Invitation.fromJson(Map<String, dynamic> json) {
    return Invitation(
      id: json['id'],
      inviterId: json['inviterId'],
      inviterNickname: json['inviterNickname'],
      inviteeId: json['inviteeId'],
      inviteeNickname: json['inviteeNickname'],
      gameType: json['gameType'],
      status: json['status'],
      roomId: json['roomId'],
      createdAt: DateTime.parse(json['createdAt']),
    );
  }

  String get gameTypeName {
    switch (gameType) {
      case 'tictactoe':
        return '틱택토';
      case 'infinite_tictactoe':
        return '무한 틱택토';
      default:
        return gameType;
    }
  }
}

class FriendProvider extends ChangeNotifier {
  final SocketService _socketService = SocketService();

  String? _myFriendCode;
  List<Friend> _friends = [];
  List<Invitation> _invitations = [];
  bool _isLoading = false;
  String? _error;
  String? _successMessage;
  bool _listenersInitialized = false;

  // 초대 받았을 때 콜백
  Function(Invitation)? onInvitationReceived;
  // 게임 시작 콜백 (초대 수락 후)
  Function(String gameType, String roomId)? onGameStart;

  String? get myFriendCode => _myFriendCode;
  List<Friend> get friends => _friends;
  List<Invitation> get invitations => _invitations;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;

  void initialize() {
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    getMyFriendCode();
    getFriends();
    getInvitations();
  }

  void _setupSocketListeners() {
    // 친구 코드 응답
    _socketService.on('friend_code', (data) {
      _myFriendCode = data['code'];
      notifyListeners();
    });

    // 친구 추가 결과
    _socketService.on('add_friend_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        if (data['friend'] != null) {
          final newFriend = Friend.fromJson(data['friend']);
          // 중복 체크
          if (!_friends.any((f) => f.id == newFriend.id)) {
            _friends.add(newFriend);
          }
        }
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 다른 사람이 나를 친구 추가했을 때
    _socketService.on('friend_added', (data) {
      final newFriend = Friend(
        id: data['id'],
        nickname: data['nickname'],
        friendCode: data['friendCode'],
        isOnline: true,
      );
      // 중복 체크
      if (!_friends.any((f) => f.id == newFriend.id)) {
        _friends.add(newFriend);
        notifyListeners();
      }
    });

    // 친구 목록 응답
    _socketService.on('friends_list', (data) {
      _friends = (data['friends'] as List)
          .map((f) => Friend.fromJson(f))
          .toList();
      _isLoading = false;
      notifyListeners();
    });

    // 친구 삭제 결과
    _socketService.on('remove_friend_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 친구 메모 수정 결과
    _socketService.on('update_friend_memo_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        final friendId = data['friendId'] as int;
        final memo = data['memo'] as String?;
        final index = _friends.indexWhere((f) => f.id == friendId);
        if (index != -1) {
          _friends[index] = _friends[index].copyWith(memo: memo);
        }
        _successMessage = data['message'];
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 초대 결과
    _socketService.on('invite_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = '초대를 보냈습니다.';
        _error = null;
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 초대 목록 응답
    _socketService.on('invitations_list', (data) {
      _invitations = (data['invitations'] as List)
          .map((i) => Invitation.fromJson(i))
          .toList();
      notifyListeners();
    });

    // 실시간 초대 받음
    _socketService.on('game_invitation', (data) {
      final invitation = Invitation.fromJson(data['invitation']);
      _invitations.insert(0, invitation);
      notifyListeners();

      // 콜백 호출 (다이얼로그 표시용)
      onInvitationReceived?.call(invitation);
    });

    // 초대 수락 결과
    _socketService.on('accept_invitation_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        // 게임 시작 콜백 호출
        final roomId = data['roomId'] as String?;
        final gameType = data['gameType'] as String?;
        if (roomId != null && gameType != null) {
          onGameStart?.call(gameType, roomId);
        }
      } else {
        _error = data['message'];
      }
      notifyListeners();
    });

    // 초대 거절 결과
    _socketService.on('decline_invitation_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = '초대를 거절했습니다.';
      } else {
        _error = data['message'];
      }
      notifyListeners();
    });

    // 초대가 거절됨
    _socketService.on('invitation_declined', (data) {
      _error = '${data['declinedBy']}님이 초대를 거절했습니다.';
      notifyListeners();
    });

    // 초대가 수락됨 (초대자에게)
    _socketService.on('invitation_accepted', (data) {
      final roomId = data['roomId'] as String?;
      final gameType = data['gameType'] as String?;
      if (roomId != null && gameType != null) {
        onGameStart?.call(gameType, roomId);
      }
    });
  }

  void getMyFriendCode() {
    _socketService.emit('get_friend_code', {});
  }

  void addFriend(String code) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('add_friend', {'friendCode': code.toUpperCase()});
  }

  void getFriends() {
    _isLoading = true;
    notifyListeners();
    _socketService.emit('get_friends', {});
  }

  void removeFriend(int friendId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('remove_friend', {'friendId': friendId});
    // 로컬에서도 즉시 제거
    _friends.removeWhere((f) => f.id == friendId);
    notifyListeners();
  }

  void updateFriendMemo(int friendId, String? memo) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('update_friend_memo', {
      'friendId': friendId,
      'memo': memo?.isEmpty == true ? null : memo,
    });
  }

  void inviteToGame(int friendId, String gameType) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('invite_to_game', {
      'friendId': friendId,
      'gameType': gameType,
    });
  }

  void getInvitations() {
    _socketService.emit('get_invitations', {});
  }

  void acceptInvitation(int invitationId) {
    _isLoading = true;
    _error = null;
    notifyListeners();
    _socketService.emit('accept_invitation', {'invitationId': invitationId});
    // 로컬에서 제거
    _invitations.removeWhere((i) => i.id == invitationId);
    notifyListeners();
  }

  void declineInvitation(int invitationId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('decline_invitation', {'invitationId': invitationId});
    // 로컬에서 제거
    _invitations.removeWhere((i) => i.id == invitationId);
    notifyListeners();
  }

  void clearMessages() {
    _error = null;
    _successMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _socketService.off('friend_code');
    _socketService.off('add_friend_result');
    _socketService.off('friend_added');
    _socketService.off('friends_list');
    _socketService.off('remove_friend_result');
    _socketService.off('update_friend_memo_result');
    _socketService.off('invite_result');
    _socketService.off('invitations_list');
    _socketService.off('game_invitation');
    _socketService.off('accept_invitation_result');
    _socketService.off('decline_invitation_result');
    _socketService.off('invitation_declined');
    _socketService.off('invitation_accepted');
    super.dispose();
  }
}
