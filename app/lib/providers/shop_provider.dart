import 'package:flutter/foundation.dart';
import '../services/socket_service.dart';
import '../services/socket_listener_registry.dart';
import '../models/shop_item.dart';

class ShopProvider extends ChangeNotifier {
  final SocketService _socketService = SocketService();
  final SocketListenerRegistry _socketListeners = SocketListenerRegistry(SocketService());

  List<ShopItem> _shopItems = [];
  List<UserItem> _userItems = [];
  UserProfileSettings? _profileSettings;
  bool _isLoading = false;
  String? _error;
  String? _successMessage;
  bool _listenersInitialized = false;
  String? _lastChangedNickname;

  List<ShopItem> get shopItems => _shopItems;
  List<UserItem> get userItems => _userItems;
  UserProfileSettings? get profileSettings => _profileSettings;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;
  String? get lastChangedNickname => _lastChangedNickname;

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
    // 기본 아이템은 모두 보유
    final shopItem = _shopItems.firstWhere(
      (item) => item.id == itemId,
      orElse: () => _shopItems.first,
    );
    if (shopItem.isDefault) return true;

    return _userItems.any((item) => item.itemId == itemId && !item.isExpired);
  }

  // 아이템 장착 여부 확인
  bool isEquipped(int itemId) {
    if (_profileSettings == null) return false;
    return _profileSettings!.activeFrameId == itemId ||
        _profileSettings!.activeTitleId == itemId ||
        _profileSettings!.activeThemeId == itemId ||
        _profileSettings!.activeAvatarId == itemId;
  }

  void initialize() {
    if (!_listenersInitialized) {
      _setupSocketListeners();
      _listenersInitialized = true;
    }
    getShopItems();
    getUserItems();
    getProfileSettings();
  }

  void _setupSocketListeners() {
    // 로비 재입장 시 데이터 동기화
    _socketListeners.on('lobby_joined', (_) {
      getShopItems();
      getUserItems();
      getProfileSettings();
    });

    // 상점 아이템 응답
    _socketListeners.on('shop_items', (data) {
      _shopItems = (data['items'] as List)
          .map((item) => ShopItem.fromJson(item))
          .toList();
      _isLoading = false;
      notifyListeners();
    });

    // 유저 보유 아이템 응답
    _socketListeners.on('user_items', (data) {
      _userItems = (data['items'] as List)
          .map((item) => UserItem.fromJson(item))
          .toList();
      notifyListeners();
    });

    // 프로필 설정 응답
    _socketListeners.on('profile_settings', (data) {
      if (data['settings'] != null) {
        _profileSettings = UserProfileSettings.fromJson(data['settings']);
      }
      notifyListeners();
    });

    // 구매 결과
    _socketListeners.on('purchase_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
        // 보유 아이템 새로고침
        getUserItems();
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 장착 결과
    _socketListeners.on('equip_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
        if (data['settings'] != null) {
          _profileSettings = UserProfileSettings.fromJson(data['settings']);
        }
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 장착 해제 결과
    _socketListeners.on('unequip_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
        if (data['settings'] != null) {
          _profileSettings = UserProfileSettings.fromJson(data['settings']);
        }
      } else {
        _error = data['message'];
        _successMessage = null;
      }
      notifyListeners();
    });

    // 1패 삭제 결과
    _socketListeners.on('delete_loss_result', (data) {
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

    // 닉네임 변경 결과
    _socketListeners.on('change_nickname_result', (data) {
      _isLoading = false;
      if (data['success'] == true) {
        _successMessage = data['message'];
        _error = null;
        _lastChangedNickname = data['nickname'];
      } else {
        _error = data['message'];
        _successMessage = null;
        _lastChangedNickname = null;
      }
      notifyListeners();
    });
  }

  // 상점 아이템 조회
  void getShopItems({String? category}) {
    _isLoading = true;
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
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('purchase_item', {'itemId': itemId});
  }

  // 아이템 장착
  void equipItem(int itemId) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('equip_item', {'itemId': itemId});
  }

  // 아이템 장착 해제
  void unequipItem(String category) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('unequip_item', {'category': category});
  }

  // 1패 삭제권 사용
  void deleteLoss(String gameType) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    notifyListeners();
    _socketService.emit('delete_loss', {'gameType': gameType});
  }

  // 닉네임 변경권 사용
  void changeNickname(String nickname) {
    _isLoading = true;
    _error = null;
    _successMessage = null;
    _lastChangedNickname = null;
    notifyListeners();
    _socketService.emit('change_nickname', {'nickname': nickname});
  }

  void clearMessages() {
    _error = null;
    _successMessage = null;
    _lastChangedNickname = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _socketListeners.offAll();
    super.dispose();
  }
}
