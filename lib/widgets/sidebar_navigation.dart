import 'package:flutter/material.dart';

class SidebarNavigation extends StatefulWidget {
  final Function(String) onNavigate;
  final String currentScreen;
  final String Function(String key, {String? fallback}) getText;
  final bool nsfwEnabled;

  const SidebarNavigation({
    super.key,
    required this.onNavigate,
    required this.currentScreen,
    required this.getText,
    required this.nsfwEnabled,
  });

  @override
  State<SidebarNavigation> createState() => _SidebarNavigationState();
}

class _SidebarNavigationState extends State<SidebarNavigation> {
  bool _expanded = false; // Collapsed by default

  final Map<String, List<NavigationItem>> _categories = {};

  @override
  void initState() {
    super.initState();
    _initializeCategories();
  }

  @override
  void didUpdateWidget(SidebarNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.nsfwEnabled != widget.nsfwEnabled) {
      _initializeCategories();
    }
  }

  void _initializeCategories() {
    _categories.clear();
    _categories[widget.getText(
      'downloaders_title',
      fallback: 'Descargadores',
    )] = [
      NavigationItem(
        id: 'music',
        icon: Icons.music_note,
        label: widget.getText(
          'spotify_title',
          fallback: 'Descargador de Música',
        ),
      ),
      NavigationItem(
        id: 'video',
        icon: Icons.video_library,
        label: widget.getText(
          'video_downloader_title',
          fallback: 'Descargador de Video',
        ),
      ),
    ];

    _categories[widget.getText('ias_title', fallback: 'IAs')] = [
      NavigationItem(
        id: 'foraai',
        icon: Icons.auto_awesome,
        label: widget.getText('foraai_title', fallback: 'ForaAI'),
      ),
      NavigationItem(
        id: 'images',
        icon: Icons.image,
        label: widget.getText('ai_image_title', fallback: 'Imágenes'),
      ),
    ];

    _categories[widget.getText('tools_title', fallback: 'Herramientas')] = [
      // NavigationItem(
      //   id: 'notes',
      //   icon: Icons.note,
      //   label: widget.getText('notes_title', fallback: 'Notas'),
      // ),
      NavigationItem(
        id: 'player', 
        icon: Icons.play_circle_fill, 
        label: widget.getText('player_reproducer', fallback: 'Reproductor'),
      ),
      NavigationItem(
        id: 'translate',
        icon: Icons.translate,
        label: widget.getText('translate_title', fallback: 'Traductor'),
      ),
      NavigationItem(
        id: 'qr',
        icon: Icons.qr_code,
        label: widget.getText('qr_title', fallback: 'Generador QR'),
      ),
    ];

    if (widget.nsfwEnabled) {
      _categories[widget.getText('others_title', fallback: 'Otros')] = [
        NavigationItem(
          id: 'r34',
          icon: Icons.image_search,
          label: widget.getText('r34_title', fallback: 'R34 Buscador'),
        ),
      ];
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _expanded ? 150 : 60,
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          right: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
        ),
      ),
      child: Column(
        children: [
          // App Logo / Header
          Container(
            height: 60,
            padding: EdgeInsets.symmetric(horizontal: _expanded ? 16 : 0),
            alignment: Alignment.center,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.flash_on,
                    color: Colors.purpleAccent,
                    size: 20,
                  ),
                ),
                if (_expanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.getText('title', fallback: 'Forawn'),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Categories
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final category in _categories.entries)
                  _buildCategory(category.key, category.value),
              ],
            ),
          ),

          // Toggle button
          // const Divider(height: 1, color: Colors.white24),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              height: 50,
              alignment: Alignment.center,
              child: Icon(
                _expanded ? Icons.chevron_left : Icons.chevron_right,
                color: Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategory(String categoryName, List<NavigationItem> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Category title (only visible when expanded)
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 4),
            child: Text(
              categoryName.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white38,
                letterSpacing: 1.2,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          )
        else
          // Simple separator when collapsed
          const SizedBox(height: 12),

        ...items.map((item) => _buildNavigationItem(item)),
      ],
    );
  }

  Widget _buildNavigationItem(NavigationItem item) {
    final isSelected = widget.currentScreen == item.id;

    return InkWell(
      onTap: () => widget.onNavigate(item.id),
      child: Container(
        height: 40, // Fixed height
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: EdgeInsets.symmetric(
          horizontal: _expanded
              ? 12
              : 0, // No padding when collapsed to center properly
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? Colors.purpleAccent.withOpacity(0.2)
              : Colors.transparent,
          border: isSelected
              ? Border(left: BorderSide(color: Colors.purpleAccent, width: 3))
              : null,
        ),
        child: _expanded
            ? Row(
                children: [
                  Icon(
                    item.icon,
                    size: 20,
                    color: isSelected ? Colors.purpleAccent : Colors.white70,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        fontSize: 13,
                        color: isSelected ? Colors.white : Colors.white70,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : Center(
                // Centered icon when collapsed
                child: Icon(
                  item.icon,
                  size: 20,
                  color: isSelected ? Colors.purpleAccent : Colors.white70,
                ),
              ),
      ),
    );
  }
}

class NavigationItem {
  final String id;
  final IconData icon;
  final String label;

  NavigationItem({required this.id, required this.icon, required this.label});
}
