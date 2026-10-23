import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/candy_theme.dart';
import '../widgets/cartoon/cartoon_card.dart';
import '../widgets/cartoon/chunky_button.dart';
import '../widgets/cartoon/duo_mascot.dart';
import '../widgets/cartoon/floating_bg.dart';
import '../widgets/cartoon/pop_in.dart';

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
    {
      'value': 'bug',
      'label': '버그 신고',
      'icon': Icons.bug_report,
      'color': CandyColors.pink,
    },
    {
      'value': 'suggestion',
      'label': '건의사항',
      'icon': Icons.lightbulb,
      'color': CandyColors.sun,
    },
    {
      'value': 'account',
      'label': '계정 문의',
      'icon': Icons.person,
      'color': CandyColors.sky,
    },
    {
      'value': 'other',
      'label': '기타',
      'icon': Icons.help,
      'color': CandyColors.grape,
    },
  ];

  @override
  void initState() {
    super.initState();
    _loadMyInquiries();
    _checkUnreadAndShowHistory();
  }

  Future<void> _checkUnreadAndShowHistory() async {
    try {
      final count = await _apiService.getUnreadInquiryCount();
      if (count > 0 && mounted) {
        setState(() => _showHistory = true);
      }
    } catch (_) {}
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
      if (!mounted) return;
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
            backgroundColor: CandyColors.mintDeep,
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
            backgroundColor: CandyColors.pinkDeep,
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
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
      body: FloatingBackground(
        child: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          child: _showHistory ? _buildHistoryView() : _buildFormView(),
        ),
      ),
    );
  }

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontWeight: FontWeight.w900,
      fontSize: 16,
      color: CandyColors.ink,
    ),
  );

  Widget _buildFormView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PopIn(
              child: CartoonCard(
                color: CandyColors.sky,
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: const [
                    DuoMascot(size: 56, mood: MascotMood.cheer),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '무엇이든 말씀해 주세요!\n듀오가 열심히 읽어볼게요',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            _label('문의 유형'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _categories.map((cat) {
                final isSelected = _selectedCategory == cat['value'];
                final color = cat['color'] as Color;
                return GestureDetector(
                  onTap: () => setState(
                    () => _selectedCategory = cat['value'] as String,
                  ),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    constraints: const BoxConstraints(minHeight: 44),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isSelected ? color : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: CandyColors.ink,
                        width: CandyTheme.outline,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: CandyColors.ink,
                          offset: Offset(0, isSelected ? 4 : 0),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          cat['icon'] as IconData,
                          size: 20,
                          color: isSelected ? Colors.white : color,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          cat['label'] as String,
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: isSelected ? Colors.white : CandyColors.ink,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            _label('제목'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                hintText: '문의 제목을 입력하세요',
                filled: true,
                fillColor: Colors.white,
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return '제목을 입력해주세요';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _label('내용'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _contentController,
              decoration: const InputDecoration(
                hintText:
                    '문의 내용을 상세히 입력해주세요.\n\n버그 신고의 경우:\n- 어떤 상황에서 발생했는지\n- 어떤 증상이 나타났는지',
                filled: true,
                fillColor: Colors.white,
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
            ChunkyButton(
              onPressed: _isLoading ? null : _submitInquiry,
              icon: _isLoading ? null : Icons.send_rounded,
              label: _isLoading ? null : '문의 등록',
              child: _isLoading
                  ? const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.white,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 18),
            CartoonCard(
              color: CandyColors.creamDeep,
              shadow: 3,
              padding: const EdgeInsets.all(12),
              child: Row(
                children: const [
                  Icon(Icons.info_outline, color: CandyColors.ink, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '문의에 대한 답변은 보통 1-2일 내에 처리됩니다.',
                      style: TextStyle(
                        color: CandyColors.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: const [
              DuoMascot(size: 110, mood: MascotMood.sad),
              SizedBox(height: 16),
              Text(
                '문의 내역이 아직 없어요',
                style: TextStyle(
                  color: CandyColors.ink,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 6),
              Text(
                '궁금한 점이 생기면 언제든 남겨주세요!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: CandyColors.inkSoft,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: CandyColors.pink,
      onRefresh: _loadMyInquiries,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        itemCount: _myInquiries.length,
        itemBuilder: (context, index) {
          final inquiry = _myInquiries[index];
          return PopIn(
            delay: Duration(milliseconds: math.min(index, 8) * 50),
            child: _buildInquiryCard(inquiry),
          );
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

    final status = (inquiry['status'] as String?) ?? 'pending';
    final hasReply = inquiry['reply'] != null;
    final isUnread = hasReply && inquiry['is_read'] != true;

    Color statusColor;
    String statusText;
    switch (status) {
      case 'pending':
        statusColor = CandyColors.tangerine;
        statusText = '대기중';
        break;
      case 'replied':
        statusColor = CandyColors.mint;
        statusText = isUnread ? '새 답변' : '답변완료';
        break;
      case 'closed':
        statusColor = const Color(0xFFB9B3C9);
        statusText = '완료';
        break;
      default:
        statusColor = const Color(0xFFB9B3C9);
        statusText = status;
    }
    final catColor = category['color'] as Color;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: CartoonCard(
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(CandyTheme.radius - 3),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              onExpansionChanged: (expanded) {
                if (expanded && isUnread) {
                  _markAsRead(inquiry);
                }
              },
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: catColor,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: CandyColors.ink, width: 2),
                ),
                child: Icon(
                  category['icon'] as IconData,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              title: Text(
                inquiry['title'] ?? '',
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: CandyColors.ink,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: isUnread ? CandyColors.pink : statusColor,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: CandyColors.ink, width: 1.5),
                      ),
                      child: Text(
                        statusText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _formatDate(inquiry['created_at']),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CandyColors.inkSoft,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '문의 내용',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                          color: CandyColors.ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: CandyColors.cream,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: CandyColors.ink, width: 2),
                        ),
                        child: Text(
                          inquiry['content'] ?? '',
                          style: const TextStyle(color: CandyColors.ink),
                        ),
                      ),
                      if (hasReply) ...[
                        const SizedBox(height: 16),
                        const Text(
                          '답변',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 13,
                            color: CandyColors.ink,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD8F8EE),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: CandyColors.ink,
                              width: 2,
                            ),
                          ),
                          child: Text(
                            inquiry['reply'],
                            style: const TextStyle(color: CandyColors.ink),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
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
