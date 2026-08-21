# TRI-NET iOS design bar

This bar turns the Dala style reference into testable native iOS rules. The
design-loop process is evaluated from rendered physical-device screens, not
from source code alone.

## Visual system

- Canvas: `#000000`.
- Primary text: `#FFFFFF`; secondary text: `#BDBDBD`.
- Iris `#8052FF` is reserved for the primary action. Use at most one filled
  Iris action per screen.
- Amber `#FFB829` identifies attention and provisional states. Verdant
  `#15846E` identifies verified or live states. Destructive call actions remain
  system red.
- Do not use opaque gray cards, decorative borders, drop shadows, or gradients.
  Inputs may use a low-opacity white fill to communicate editability.
- Use open spacing, light rounded display type, and lowercase product language.
- The constellation motif belongs only in identity, onboarding, and empty
  states. It must not sit under chat text or call controls.

## Interaction and accessibility

- Every interactive hit target is at least 44 by 44 points.
- Use Dynamic Type-compatible system fonts for functional copy.
- Every call state is written as text and exposed to VoiceOver; color is never
  the only status signal.
- Incoming, accept, decline, mute, camera, route, and end-call controls have
  explicit accessibility labels.
- Motion is optional. Respect Reduce Motion and keep the same information when
  animation is disabled.
- Normal-size text must meet a WCAG contrast ratio of at least 4.5:1.
- Nickname search says that it is exact. A configured route is not described as
  online until a service health check confirms it.

## Per-screen acceptance

1. Home shows the saved call address, its global or local scope, exact nickname
   search, recent conversations, and nearby signed peers.
2. Chat keeps audio and video call actions in the header and one filled send
   action in the composer.
3. Outgoing call displays a textual sequence: Calling, Connecting, Ringing,
   Connected, or Ended.
4. Incoming call identifies the caller by verified nickname or display name,
   never by a raw IP address. Accept and Decline are reachable with one tap.
5. Settings distinguish public production URLs from local development routes.

## Review loop

For every material UI change:

1. Build with the repository's existing DerivedData and install on both
   connected physical iPhones.
2. Capture the rendered result on both device sizes.
3. Run three independent binary reviews with fresh context:
   requirements compliance, design-system compliance, and visual craft.
4. Fix every failed item and repeat. Approval requires three passes and the
   accessibility checks above.

## Sources

- Design-loop process: <https://gomymy64.github.io/design-loop-cheatsheet/>
- Apple accessibility guidance:
  <https://developer.apple.com/design/human-interface-guidelines/accessibility>
- Apple CallKit: <https://developer.apple.com/documentation/callkit>
- Dala visual tokens: [DALA_STYLE_REFERENCE.md](DALA_STYLE_REFERENCE.md),
  summarized from the user-supplied reference.
