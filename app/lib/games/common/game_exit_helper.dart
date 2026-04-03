import 'package:flutter/material.dart';

Future<void> showGameExitDialog({
  required BuildContext context,
  required Color accentColor,
  required String message,
  required VoidCallback onExit,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Icon(Icons.exit_to_app, color: accentColor),
          const SizedBox(width: 8),
          const Text('게임 나가기'),
        ],
      ),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('취소'),
        ),
        ElevatedButton(
          onPressed: () {
            onExit();
            Navigator.pop(dialogContext);
            Navigator.pop(context);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: Colors.white,
          ),
          child: const Text('나가기'),
        ),
      ],
    ),
  );
}
