import 'dart:io';
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../utils/color_utils.dart';

class NoteCard extends StatelessWidget {
  final Note note;
  final VoidCallback? onTap;

  const NoteCard({super.key, required this.note, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = Color(note.backgroundColorValue);
    final textColor = readableTextColorFor(bg);

    return Card(
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (note.imagePath != null && File(note.imagePath!).existsSync())
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(note.imagePath!), width: 100, height: 150, fit: BoxFit.cover),
                )
              else
                Container(
                  width: 100,
                  height: 150,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.note, color: textColor.withOpacity(0.9)),
                ),
              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            note.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: textColor, fontWeight: FontWeight.w600, fontSize: 20),
                          ),
                        ),
                        if (note.pinned) Icon(Icons.push_pin, size: 16, color: textColor.withOpacity(0.85)),
                      ],
                    ),
                    const SizedBox(height: 6),

                    Text(
                      note.description.isEmpty ? 'Sin descripción' : note.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor.withOpacity(0.9),
                        fontSize: 13.5,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 8),

                    Row(
                      children: [
                        if (note.category != null && note.category!.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: textColor.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Text(
                              note.category!,
                              style: TextStyle(color: textColor, fontSize: 12),
                            ),
                          ),
                        const Spacer(),
                        // Text(
                        //   note.createdAt.toLocal().toString().split('.').first,
                        //   style: TextStyle(color: textColor.withOpacity(0.7), fontSize: 11),
                        // ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
