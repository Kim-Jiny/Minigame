mixin ProviderFeedback {
  bool _isLoading = false;
  String? _error;
  String? _successMessage;

  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;

  void setLoading(bool value) {
    _isLoading = value;
  }

  void startLoading({bool clearSuccess = true}) {
    _isLoading = true;
    _error = null;
    if (clearSuccess) {
      _successMessage = null;
    }
  }

  void setError(String? message) {
    _error = message;
    if (message != null) {
      _successMessage = null;
    }
  }

  void setSuccess(String? message) {
    _successMessage = message;
    if (message != null) {
      _error = null;
    }
  }

  void clearFeedback() {
    _error = null;
    _successMessage = null;
  }
}
