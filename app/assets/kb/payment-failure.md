---
id: payment-failure
title: Payment fails or checkout cannot complete
category: Checkout & Payment
keywords: payment, checkout, card, purchase, buy, stuck, failed, failure, cannot complete, error
---

# Payment fails or checkout cannot complete

## Customer Steps
1. Confirm the card details and billing ZIP code.
2. Retry once after refreshing checkout totals.
3. Use another payment method if the purchase window is time-sensitive.

## Team Action
Capture the payment intent error code and route users to a retryable checkout state.

## Engineering Signal
Likely payment intent timeout, declined authorization, or checkout session mismatch.
