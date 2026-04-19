---
id: checkout-coupon-disappears
title: Coupon discount disappears after returning to checkout
category: Checkout & Payment
keywords: coupon, promo code, discount, checkout, back, return, disappears, missing discount, cart, code
---

# Coupon discount disappears after returning to checkout

## Customer Steps
1. Stay on checkout after applying the promo code when possible.
2. If the discount disappears, remove and reapply the promo code before payment.
3. Refresh checkout totals before entering payment details.

## Team Action
Persist applied promotion state across checkout route transitions and cart quote refreshes.

## Engineering Signal
Likely client-side checkout state reset or quote refresh dropping promotion metadata.
