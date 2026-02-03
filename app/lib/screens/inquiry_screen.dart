import 'package:flutter/material.dart';
import '../services/api_service.dart';

class InquiryScreen extends StatefulWidget {
  const InquiryScreen({super.key});

  @override
  State<InquiryScreen> createState() => _InquiryScreenState();
}

class _InquiryScreenState extends State<InquiryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  final _apiService = ApiService();

  String _selectedCategory = 'bug';
  bool _isLoading = false;
  List<Map<String, dynamic>> _myInquiries = [];
  bool _showHistory = false;

  final List<Map<String, dynamic>> _categories = [
    {'value': 'bug', 'label': '버그 신고', 'icon': Icons.bug_report, 'color': Colors.red},
    {'value': 'suggestion', 'label': '건의사항', 'icon': Icons.lightbulb, 'color': Colors.amber},
    {'value': 'account', 'label': '계정 문의', 'icon': Icons.person, 'color': Colors.blue},
    {'value': 'other', 'label': '기타', 'icon': Icons.help, 'color': Colors.grey},
  ];

  @override
  void initState() {
    super.initState();
    _loadMyInquiries();
    _checkUnreadAndShowHistory();
  }

  Future<void> _checkUnreadAndShowHistory() async {
    final count = await _apiService.getUnreadInquiryCount();
    if (count > 0 && mounted) {
      setState(() => _showHistory = true);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _loadMyInquiries() async {
    try {
      final inquiries = await _apiService.getMyInquiries();
      setState(() {
        _myInquiries = inquiries;
      });
    } catch (e) {
      debugPrint('Failed to load inquiries: $e');
    }
  }

  Future<void> _submitInquiry() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      await _apiService.submitInquiry(
        category: _selectedCategory,
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('문의가 등록되었습니다.'),
            backgroundColor: Colors.green,
          ),
        );

        _titleController.clear();
        _contentController.clear();
        await _loadMyInquiries();
        setState(() => _showHistory = true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('문의 등록 실패: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('문의하기'),
        actions: [
          TextButton.icon(
            onPressed: () => setState(() => _showHistory = !_showHistory),
            icon: Icon(
              _showHistory ? Icons.edit : Icons.history,
              color: Colors.white,
            ),
            label: Text(
              _showHistory ? '작성' : '내 문의',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: _showHistory ? _buildHistoryView() : _buildFormView(),
      ),
    );
  }

  Widget _buildFormView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 카테고리 선택
            const Text(
              '문의 유형',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _categories.map((cat) {
                final isSelected = _selectedCategory == cat['value'];
                return ChoiceChip(
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        cat['icon'] as IconData,
                        size: 18,
                        color: isSelected ? Colors.white : cat['color'] as Color,
                      ),
                      const SizedBox(width: 6),
                      Text(cat['label'] as String),
                    ],
                  ),
                  selected: isSelected,
                  onSelected: (_) => setState(() => _selectedCategory = cat['value'] as String),
                  selectedColor: cat['color'] as Color,
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : Colors.black87,
                  ),
                );
              }).toList(),
            ),

            const SizedBox(height: 24),

            // 제목
            const Text(
              '제목',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _titleController,
              decoration: InputDecoration(
                hintText: '문의 제목을 입력하세요',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '제목을 입력해주세요';
                }
                return null;
              },
            ),

            const SizedBox(height: 16),

            // 내용
            const Text(
              '내용',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            TextFormField(
              controller: _contentController,
              decoration: InputDecoration(
                hintText: '문의 내용을 상세히 입력해주세요.\n\n버그 신고의 경우:\n- 어떤 상황에서 발생했는지\n- 어떤 증상이 나타났는지',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                fillColor: Colors.grey.shade50,
              ),
              maxLines: 8,
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '내용을 입력해주세요';
                }
                return null;
              },
            ),

            const SizedBox(height: 24),

            // 제출 버튼
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _submitInquiry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '문의 등록',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ),

            const SizedBox(height: 16),

            // 안내 문구
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue.shade700, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '문의에 대한 답변은 보통 1-2일 내에 처리됩니다.',
                      style: TextStyle(color: Colors.blue.shade700, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryView() {
    if (_myInquiries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              '문의 내역이 없습니다',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMyInquiries,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _myInquiries.length,
        itemBuilder: (context, index) {
          final inquiry = _myInquiries[index];
          return _buildInquiryCard(inquiry);
        },
      ),
    );
  }

  Future<void> _markAsRead(Map<String, dynamic> inquiry) async {
    if (inquiry['reply'] != null && inquiry['is_read'] != true) {
      await _apiService.markInquiryAsRead(inquiry['id']);
      setState(() {
        inquiry['is_read'] = true;
      });
    }
  }

  Widget _buildInquiryCard(Map<String, dynamic> inquiry) {
    final category = _categories.firstWhere(
      (c) => c['value'] == inquiry['category'],
      orElse: () => _categories.last,
    );

    final status = inquiry['status'] as String;
    final hasReply = inquiry['reply'] != null;
    final isUnread = hasReply && inquiry['is_read'] != true;

    Color statusColor;
    String statusText;
    switch (status) {
      case 'pending':
        statusColor = Colors.orange;
        statusText = '대기중';
        break;
      case 'replied':
        statusColor = Colors.green;
        statusText = isUnread ? '새 답변' : '답변완료';
        break;
      case 'closed':
        statusColor = Colors.grey;
        statusText = '완료';
        break;
      default:
        statusColor = Colors.grey;
        statusText = status;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded && isUnread) {
            _markAsRead(inquiry);
          }
        },
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (category['color'] as Color).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            category['icon'] as IconData,
            color: category['color'] as Color,
            size: 24,
          ),
        ),
        title: Text(
          inquiry['title'] ?? '',
          style: const TextStyle(fontWeight: FontWeight.w600),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isUnread ? Colors.red : statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusText,
                style: TextStyle(
                  color: isUnread ? Colors.white : statusColor,
                  fontSize: 12,
                  fontWeight: isUnread ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDate(inquiry['created_at']),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '문의 내용',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(inquiry['content'] ?? ''),
                ),
                if (hasReply) ...[
                  const SizedBox(height: 16),
                  const Text(
                    '답변',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Text(inquiry['reply']),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final date = DateTime.parse(dateStr);
      return '${date.year}.${date.month.toString().padLeft(2, '0')}.${date.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }
}
