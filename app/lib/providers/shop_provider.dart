import 'dart:async';
import 'package:flutter/foundation.dart';
import 'mixins/provider_feedback.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../models/shop_item.dart';

class ShopProvider extends ChangeNotifier with ProviderFeedback {
  final SocketService _socketService = SocketService();
  late final SocketListenerRegistry _socketListeners = SocketListenerRegistry(_socketService);

  List<ShopItem> _shopItems = [];
  List<UserItem> _userItems = [];
  UserProfileSettings? _profileSettings;
  bool _listenersInitialized = false;
  bool _hasFetchedInitialData = false;
  String? _lastChangedNickname;
  Timer? _expiryTimer;

  List<ShopItem> get shopItems => _shopItems;
  List<UserItem> get userItems => _userItems;
  UserProfileSettings? get profileSettings => _profileSettings;
  String? get lastChangedNickname => _lastChangedNickname;
  bool get hasFetchedInitialData => _hasFetchedInitialData;

  // 카테고리별 필터링
  List<ShopItem> getItemsByCategory(ShopCategory category) {
    return _shopItems.where((item) => item.category == category).toList();
  }

  // 보유 아이템 카테고리별 필터링
  List<UserItem> getUserItemsByCategory(ShopCategory category) {
    return _userItems.where((item) => item.item?.category == category).toList();
  }

  // 아이템 보유 여부 확인
  bool hasItem(int itemId) {
    if (_shopItems.isEmpty) return false;
    // 기본 아이템은 모두 보유
    final shopItem = _shopItems.firstWhere(
      (item) => item.id == itemId,
      orElse: () => _shopItems.first,
    );
    if (shopItem.isDefault) return true;

    return _userItems.any((item) => item.itemId == itemId && !item.isExpired);
  }

  /// 보유 기록(UserItem). 기간제는 만료일을 가진다. 없으면 null.
  UserItem? ownedRecord(int itemId) {
    UserItem? best;
    for (final u in _userItems) {
      if (u.itemId != itemId || u.isExpired) continue;
      // 영구 > 더 늦게 만료되는 쪽
      if (best == null ||
          u.expiresAt == null ||
          (best.expiresAt != null && u.expiresAt!.isAfter(best.expiresAt!))) {
        best = u;
      }
    }
    return best;
  }

  // 아이템 장착 여부 확인 (만료된 기간제는 서버 갱신 전이라도 장착 아님으로 본다)
  bool isEquipped(int itemId) {
    final s = _profileSettings;
    if (s == null) return false;
    final active = s.activeFrameId == itemId ||
        s.activeTitleId == itemId ||
        s.activeThemeId == itemId ||
        s.activeAvatarId == itemId ||
        s.activeMascotId == itemId;
    if (!active) return false;
    final expiredOnly = _userItems.any((u) => u.itemId == itemId && u.isExpired) &&
        ownedRecord(itemId) == null;
    return !expiredOnly;
  }

  /// 소켓이 연결돼 있으면 보유 아이템/프로필 설정을 다시 받는다(앱 복귀·상점 진입 시).
  void refreshOwnership() {
    if (!_socketService.isReady) return;
    getUserItems();
    getProfileSettings();
  }

  // 장착 중인 기간제 아이템이 만료되는 순간 서버 상태를 다시 받아 기본값으로 돌아가게 한다.
  void _scheduleExpiryRefresh() {
    _expiryTimer?.cancel();
    final s = _profileSettings;
    if (s == null) return;
    DateTime? soonest;
    for (final id in [
      s.activeFrameId,
      s.activeTitleId,
      s.activeThemeId,
      s.activeAvatarId,
      s.activeMascotId,
    ]) {
      if (id == null) continue;
      final exp = ownedRecord(id)?.expiresAt;
      if (exp != null && (soonest == null || exp.isBefore(soonest))) {
        soonest = exp;
      }
    }
    if (soonest == null) return;
    var wait = soonest.difference(DateTime.now()) + const Duration(seconds: 2);
    if (wait > const Duration(days: 20)) return; // 타이머 한도 보호
    if (wait.isNegative) wait = const Duration(seconds: 2);
    _expiryTimer = Timer(wait, () {
      notifyListeners(); // isEquipped 가 즉시 만료를 반영
      refreshOwnership();
    });
  }

  void initialize() {
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    if (_socketService.isReady) {
      refreshAll();
    }
  }

  void refreshAll() {
    _hasFetchedInitialData = true;
    getShopItems();
    getUserItems();
    getProfileSettings();
  }

  void _setupSocketListeners() {
    // 로비 재입장 시 데이터 동기화
    _socketListeners.on('lobby_joined', (_) {
      refreshAll();
    });

    // 상점 아이템 응답
    _socketListeners.on('shop_items', (data) {
      _shopItems = (data['items'] as List)
          .map((item) => ShopItem.fromJson(item))
          .toList();
      setLoading(false);
      notifyListeners();
    });

    // 유저 보유 아이템 응답
    _socketListeners.on('user_items', (data) {
      _userItems = (data['items'] as List)
          .map((item) => UserItem.fromJson(item))
          .toList();
      _scheduleExpiryRefresh();
      notifyListeners();
    });

    // 프로필 설정 응답
    _socketListeners.on('profile_settings', (data) {
      if (data['settings'] != null) {
        _profileSettings = UserProfileSettings.fromJson(data['settings']);
        _scheduleExpiryRefresh();
      }
      notifyListeners();
    });

    // 구매 결과
    _socketListeners.on('purchase_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        // 보유 아이템 새로고침
        getUserItems();
        getProfileSettings();
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 장착 결과
    _socketListeners.on('equip_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        if (data['settings'] != null) {
          _profileSettings = UserProfileSettings.fromJson(data['settings']);
        }
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 장착 해제 결과
    _socketListeners.on('unequip_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        if (data['settings'] != null) {
          _profileSettings = UserProfileSettings.fromJson(data['settings']);
        }
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 1패 삭제 결과
    _socketListeners.on('delete_loss_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
      } else {
        setError(data['message']);
      }
      notifyListeners();
    });

    // 닉네임 변경 결과
    _socketListeners.on('change_nickname_result', (data) {
      setLoading(false);
      if (data['success'] == true) {
        setSuccess(data['message']);
        _lastChangedNickname = data['nickname'];
      } else {
        setError(data['message']);
        _lastChangedNickname = null;
      }
      notifyListeners();
    });
  }

  // 상점 아이템 조회
  void getShopItems({String? category}) {
    setLoading(true);
    notifyListeners();
    _socketService.emit('get_shop_items', category != null ? {'category': category} : {});
  }

  // 보유 아이템 조회
  void getUserItems() {
    _socketService.emit('get_user_items', {});
  }

  // 프로필 설정 조회
  void getProfileSettings() {
    _socketService.emit('get_profile_settings', {});
  }

  // 아이템 구매
  void purchaseItem(int itemId) {
    startLoading();
    notifyListeners();
    _socketService.emit('purchase_item', {'itemId': itemId});
  }

  // 아이템 장착
  void equipItem(int itemId) {
    startLoading();
    notifyListeners();
    _socketService.emit('equip_item', {'itemId': itemId});
  }

  // 아이템 장착 해제
  void unequipItem(String category) {
    startLoading();
    notifyListeners();
    _socketService.emit('unequip_item', {'category': category});
  }

  // 패배 삭제권 사용
  void deleteLoss(String gameType, {int count = 1, int price = 50}) {
    startLoading();
    notifyListeners();
    _socketService.emit('delete_loss', {'gameType': gameType, 'count': count, 'price': price});
  }

  // 닉네임 변경권 사용
  void changeNickname(String nickname) {
    startLoading();
    _lastChangedNickname = null;
    notifyListeners();
    _socketService.emit('change_nickname', {'nickname': nickname});
  }

  void clearMessages() {
    clearFeedback();
    _lastChangedNickname = null;
    notifyListeners();
  }

  void resetState() {
    _shopItems = [];
    _userItems = [];
    _profileSettings = null;
    _expiryTimer?.cancel();
    _hasFetchedInitialData = false;
    _lastChangedNickname = null;
    clearFeedback();
    notifyListeners();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    _socketListeners.offAll();
    super.dispose();
  }
}
