import 'dart:io';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
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
    // iOS: 광고 식별자(IDFA) 사용을 위한 ATT(추적 투명성) 권한 요청.
    // AdMob 초기화 전에 호출해야 IDFA 사용 여부가 광고 SDK에 반영된다.
    if (Platform.isIOS) {
      await _requestTrackingAuthorization();
    }
    await MobileAds.instance.initialize();
    _initialized = true;
    loadRewardedAd();
  }

  /// iOS ATT 팝업 요청. 아직 결정 전(notDetermined)일 때만 시스템 프롬프트를 띄운다.
  Future<void> _requestTrackingAuthorization() async {
    try {
      final status = await AppTrackingTransparency.trackingAuthorizationStatus;
      if (status == TrackingStatus.notDetermined) {
        // Apple 권장: 앱 활성 직후 안정화를 위한 짧은 지연 후 프롬프트.
        await Future.delayed(const Duration(milliseconds: 200));
        final result =
            await AppTrackingTransparency.requestTrackingAuthorization();
        debugPrint('[AdService] ATT result: $result');
      } else {
        debugPrint('[AdService] ATT already determined: $status');
      }
    } catch (e) {
      debugPrint('[AdService] ATT request failed: $e');
    }
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
