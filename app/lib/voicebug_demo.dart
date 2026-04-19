import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'cactus/engine.dart';
import 'sdk/capture_flow.dart';
import 'sdk/github_client.dart';
import 'sdk/screenshot_capture.dart';
import 'ui/voicebug_button.dart';
import 'ui/voicebug_overlay.dart';
import 'voice/stt.dart';

class VoiceBugDemo extends StatefulWidget {
  final CactusEngine engine;
  const VoiceBugDemo({super.key, required this.engine});

  @override
  State<VoiceBugDemo> createState() => _VoiceBugDemoState();
}

class _VoiceBugDemoState extends State<VoiceBugDemo> {
  late final CaptureFlowController _capture;
  final _boundaryKey = GlobalKey();

  String get _ghOwner => dotenv.get('VOICEBUG_GH_OWNER', fallback: '');
  String get _ghRepo => dotenv.get('VOICEBUG_GH_REPO', fallback: '');
  String get _ghToken => dotenv.get('VOICEBUG_GH_TOKEN', fallback: '');

  @override
  void initState() {
    super.initState();
    final screenshotCapture = ScreenshotCapture()..attach(_boundaryKey);
    _capture = CaptureFlowController(
      engine: widget.engine,
      stt: SpeechToTextService(),
      github: GitHubClient(
        owner: _ghOwner,
        repo: _ghRepo,
        token: _ghToken,
      ),
      screenshot: screenshotCapture,
    );
  }

  @override
  void dispose() {
    _capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final missingConfig = _ghOwner.isEmpty || _ghRepo.isEmpty || _ghToken.isEmpty;

    return MaterialApp(
      title: 'VoiceBug Demo',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D6A4F),
          brightness: Brightness.dark,
        ),
      ),
      home: missingConfig
          ? const Scaffold(
              body: Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Missing GitHub config.\n\n'
                    'Add to app/.env:\n'
                    'VOICEBUG_GH_OWNER=owner\n'
                    'VOICEBUG_GH_REPO=repo\n'
                    'VOICEBUG_GH_TOKEN=ghp_xxx',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                ),
              ),
            )
          : _DemoShell(capture: _capture, boundaryKey: _boundaryKey),
    );
  }
}

class _DemoShell extends StatefulWidget {
  final CaptureFlowController capture;
  final GlobalKey boundaryKey;
  const _DemoShell({required this.capture, required this.boundaryKey});

  @override
  State<_DemoShell> createState() => _DemoShellState();
}

class _DemoShellState extends State<_DemoShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RepaintBoundary(
          key: widget.boundaryKey,
          child: Scaffold(
            body: IndexedStack(
              index: _selectedIndex,
              children: const [
                _ProductListPage(),
                _CartPage(),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _selectedIndex,
              onDestinationSelected: (i) => setState(() => _selectedIndex = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.storefront), label: 'Products'),
                NavigationDestination(icon: Icon(Icons.shopping_cart), label: 'Cart'),
              ],
            ),
          ),
        ),
        VoiceBugButton(
          onTap: () => widget.capture.startCapture(context),
        ),
        VoiceBugOverlay(controller: widget.capture),
      ],
    );
  }
}

class _ProductListPage extends StatelessWidget {
  const _ProductListPage();

  static const _products = [
    _Product('Wireless Headphones', '\$79.99', 'Premium over-ear headphones with ANC'),
    _Product('USB-C Hub', '\$49.99', '7-in-1 adapter for MacBook'),
    _Product('Mechanical Keyboard', '\$129.99', 'Cherry MX Brown switches, wireless'),
    _Product('Smart Watch', '\$199.99', 'Health tracking, GPS, 5-day battery'),
    _Product('Portable Charger', '\$39.99', '20,000 mAh fast charging power bank'),
  ];

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(
          title: Text('TechShop'),
        ),
        SliverList.builder(
          itemCount: _products.length,
          itemBuilder: (context, i) {
            final p = _products[i];
            return ListTile(
              leading: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.devices, color: Colors.white24),
              ),
              title: Text(p.name),
              subtitle: Text(p.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Text(p.price, style: const TextStyle(fontWeight: FontWeight.bold)),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => _ProductDetailPage(product: p)),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Product {
  final String name;
  final String price;
  final String description;
  const _Product(this.name, this.price, this.description);
}

class _ProductDetailPage extends StatelessWidget {
  final _Product product;
  const _ProductDetailPage({required this.product});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(product.name)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 200,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.image, size: 64, color: Colors.white12),
            ),
            const SizedBox(height: 24),
            Text(product.name, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(product.price, style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: const Color(0xFF27ae60),
              fontWeight: FontWeight.bold,
            )),
            const SizedBox(height: 16),
            Text(product.description, style: Theme.of(context).textTheme.bodyLarge),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Add to Cart'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CartPage extends StatelessWidget {
  const _CartPage();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.shopping_cart_outlined, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('Your cart is empty', style: TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }
}
