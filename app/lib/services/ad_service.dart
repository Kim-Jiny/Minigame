import 'dart:io';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';

class AdService {
  static final AdService _instance = AdService._internal();
  factory AdService() => _instance;
  AdService._internal();

  RewardedAd? _rewardedAd;
  bool _isLoading = false;
  bool _initialized = false;

  // 실제 Ad Unit IDs
  static const String _androidRewardedUnitId = 'ca-app-pub-2707874353926722/6562808109';
  static const String _iosRewardedUnitId = 'ca-app-pub-2707874353926722/9933883965';

  // Google 제공 테스트 Ad Unit IDs
  static const String _androidTestRewardedUnitId = 'ca-app-pub-3940256099942544/5224354917';
  static const String _iosTestRewardedUnitId = 'ca-app-pub-3940256099942544/1712485313';

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  String get _rewardedAdUnitId {
    if (Platform.isAndroid) {
      return kDebugMode ? _androidTestRewardedUnitId : _androidRewardedUnitId;
    }
    if (Platform.isIOS) {
      return kDebugMode ? _iosTestRewardedUnitId : _iosRewardedUnitId;
    }
    return '';
  }

  bool get isRewardedAdReady => _rewardedAd != null;

  Future<void> initialize() async {
    if (!_isMobile) {
      debugPrint('[AdService] Skipping init - not a mobile platform');
      return;
    }
    await MobileAds.instance.initialize();
    _initialized = true;
    loadRewardedAd();
  }

  void loadRewardedAd() {
    if (!_initialized || _isLoading || _rewardedAd != null) return;
    _isLoading = true;

    RewardedAd.load(
      adUnitId: _rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          _rewardedAd = ad;
          _isLoading = false;
          debugPrint('[AdService] Rewarded ad loaded');
        },
        onAdFailedToLoad: (error) {
          _isLoading = false;
          debugPrint('[AdService] Rewarded ad failed to load: ${error.message}');
          Future.delayed(const Duration(seconds: 5), loadRewardedAd);
        },
      ),
    );
  }

  Future<bool> showRewardedAd({required VoidCallback onRewarded}) async {
    if (_rewardedAd == null) {
      debugPrint('[AdService] Rewarded ad not ready');
      loadRewardedAd();
      return false;
    }

    final ad = _rewardedAd!;
    _rewardedAd = null;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        ad.dispose();
        loadRewardedAd();
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        debugPrint('[AdService] Failed to show: ${error.message}');
        ad.dispose();
        loadRewardedAd();
      },
    );

    await ad.show(onUserEarnedReward: (_, reward) {
      onRewarded();
    });

    return true;
  }

  void dispose() {
    _rewardedAd?.dispose();
    _rewardedAd = null;
  }
}
