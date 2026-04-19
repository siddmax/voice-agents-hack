import 'package:flutter_test/flutter_test.dart';
import 'package:syndai/sdk/feedback_kb.dart';

void main() {
  test('markdown parser extracts metadata and resolution sections', () {
    final article = FeedbackKbArticle.fromMarkdown(
      sourcePath: 'assets/kb/test.md',
      markdown: '''---
id: checkout-coupon-disappears
title: Coupon discount disappears after returning to checkout
category: Checkout & Payment
keywords: coupon, promo code, discount, checkout
---

# Coupon discount disappears after returning to checkout

## Customer Steps
1. Reapply the promo code.
2. Refresh checkout totals.

## Team Action
Persist promotion state across checkout navigation.

## Engineering Signal
Quote refresh is dropping promotion metadata.
''',
    );

    expect(article.id, 'checkout-coupon-disappears');
    expect(article.title, contains('Coupon discount'));
    expect(article.keywords, contains('promo code'));
    expect(article.customerSteps, [
      'Reapply the promo code.',
      'Refresh checkout totals.',
    ]);
    expect(article.teamAction, contains('Persist promotion state'));
  });

  test(
    'search ranks coupon checkout article for disappearing discount',
    () async {
      final coupon = FeedbackKbArticle.fromMarkdown(
        sourcePath: 'assets/kb/checkout-coupon-disappears.md',
        markdown: '''---
id: checkout-coupon-disappears
title: Coupon discount disappears after returning to checkout
category: Checkout & Payment
keywords: coupon, promo code, discount, checkout, back, disappears
---

# Coupon discount disappears after returning to checkout

## Customer Steps
1. Reapply the promo code.

## Team Action
Persist applied promotion state across checkout route transitions.

## Engineering Signal
Quote refresh is dropping promotion metadata.
''',
      );
      final payment = FeedbackKbArticle.fromMarkdown(
        sourcePath: 'assets/kb/payment-failure.md',
        markdown: '''---
id: payment-failure
title: Payment fails or checkout cannot complete
category: Checkout & Payment
keywords: payment, card, failed
---

# Payment fails or checkout cannot complete

## Customer Steps
1. Retry payment.

## Team Action
Capture payment intent errors.

## Engineering Signal
Payment intent timeout.
''',
      );
      final kb = FeedbackKnowledgeBase.inMemory([payment, coupon]);

      final matches = await kb.search(
        transcript:
            'When I apply a coupon, go back, and return to checkout, the discount disappears.',
        category: 'Checkout & Payment',
        themes: const ['coupon', 'checkout'],
        painPoints: const ['discount disappears'],
      );

      expect(matches, isNotEmpty);
      expect(matches.first.article.id, 'checkout-coupon-disappears');
      final resolution = kb.buildResolution(matches);
      expect(resolution?.summary, contains('Coupon discount disappears'));
      expect(
        resolution?.teamActions.first,
        contains('Persist applied promotion state'),
      );
    },
  );
}
