---
name: Premium Commerce Interface
colors:
  surface: '#f8f9fa'
  surface-dim: '#d9dadb'
  surface-bright: '#f8f9fa'
  surface-container-lowest: '#ffffff'
  surface-container-low: '#f3f4f5'
  surface-container: '#edeeef'
  surface-container-high: '#e7e8e9'
  surface-container-highest: '#e1e3e4'
  on-surface: '#191c1d'
  on-surface-variant: '#404944'
  inverse-surface: '#2e3132'
  inverse-on-surface: '#f0f1f2'
  outline: '#707974'
  outline-variant: '#bfc9c3'
  surface-tint: '#2b6954'
  primary: '#003527'
  on-primary: '#ffffff'
  primary-container: '#064e3b'
  on-primary-container: '#80bea6'
  inverse-primary: '#95d3ba'
  secondary: '#575e70'
  on-secondary: '#ffffff'
  secondary-container: '#d9dff5'
  on-secondary-container: '#5c6274'
  tertiary: '#4f1f19'
  on-tertiary: '#ffffff'
  tertiary-container: '#6b342d'
  on-tertiary-container: '#ea9e93'
  error: '#ba1a1a'
  on-error: '#ffffff'
  error-container: '#ffdad6'
  on-error-container: '#93000a'
  primary-fixed: '#b0f0d6'
  primary-fixed-dim: '#95d3ba'
  on-primary-fixed: '#002117'
  on-primary-fixed-variant: '#0b513d'
  secondary-fixed: '#dce2f7'
  secondary-fixed-dim: '#c0c6db'
  on-secondary-fixed: '#141b2b'
  on-secondary-fixed-variant: '#404758'
  tertiary-fixed: '#ffdad5'
  tertiary-fixed-dim: '#ffb4a9'
  on-tertiary-fixed: '#380d08'
  on-tertiary-fixed-variant: '#6e372f'
  background: '#f8f9fa'
  on-background: '#191c1d'
  surface-variant: '#e1e3e4'
typography:
  display-lg:
    fontFamily: Geist
    fontSize: 32px
    fontWeight: '700'
    lineHeight: 40px
    letterSpacing: -0.02em
  headline-md:
    fontFamily: Geist
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
    letterSpacing: -0.01em
  headline-sm:
    fontFamily: Geist
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  body-lg:
    fontFamily: Geist
    fontSize: 16px
    fontWeight: '400'
    lineHeight: 24px
  body-md:
    fontFamily: Geist
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  price-lg:
    fontFamily: Geist
    fontSize: 18px
    fontWeight: '500'
    lineHeight: 24px
  label-bold:
    fontFamily: Geist
    fontSize: 12px
    fontWeight: '600'
    lineHeight: 16px
  label-sm:
    fontFamily: Geist
    fontSize: 11px
    fontWeight: '500'
    lineHeight: 14px
rounded:
  sm: 0.25rem
  DEFAULT: 0.5rem
  md: 0.75rem
  lg: 1rem
  xl: 1.5rem
  full: 9999px
spacing:
  base: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  container-margin: 20px
  gutter: 12px
---

## Brand & Style
The design system is engineered for high-conversion mobile commerce, blending **Minimalism** with **Corporate Modern** sensibilities. The brand personality is "The Quiet Authority"—premium, trustworthy, and obsessively functional. It focuses on removing cognitive load to let product imagery lead the experience.

The visual narrative relies on extreme clarity, generous whitespace, and a sophisticated utility that mirrors high-end physical retail environments. Every interaction is designed to feel intentional and frictionless, fostering an emotional response of confidence and ease.

## Colors
The palette is anchored by **Emerald Green**, a color chosen for its associations with growth, stability, and premium retail. 

- **Primary (Emerald):** Reserved strictly for primary calls to action (Add to Cart, Checkout) and key brand moments.
- **Secondary (Ink):** Used for primary text and high-contrast iconography to ensure maximum legibility.
- **Neutral (Slate/Cloud):** A range of cool grays provides the structural scaffolding. Surfaces use subtle shifts in gray rather than heavy borders to define hierarchy.
- **Semantic:** Success and Error colors are used sparingly for stock status and form validation, maintaining high saturation to ensure they are noticed immediately.

## Typography
This design system utilizes **Geist** for its technical precision and modern character. The typographic scale is optimized for mobile scannability:

- **Product Names:** Use `headline-sm` or `headline-md` with Semi-Bold weights to create a strong anchor in the product grid.
- **Pricing:** Set in `price-lg` with Medium weight. It should be prominent but slightly subordinate to the product name.
- **Micro-copy:** Labels for "In Stock" or shipping info use `label-bold` with increased letter spacing for readability at small scales.
- **Mobile Adaptivity:** For small-screen devices, `display-lg` should be capped at 28px to prevent awkward line breaks in product titles.

## Layout & Spacing
The system follows a strict **8px grid** with a **4px baseline** for micro-adjustments. 

- **Grid Model:** A 2-column fluid grid for mobile product listings, transitioning to a single-column detailed view for product pages.
- **Margins:** 20px safe-area margins on the left and right edges of the screen to prevent "content crowding."
- **Vertical Rhythm:** Use 32px (xl) spacing between major sections (e.g., "Recommended" vs "New Arrivals") and 16px (md) between items within a category.
- **Touch Targets:** All interactive elements must maintain a minimum 44x44px hit area, regardless of their visual size.

## Elevation & Depth
Hierarchy is established through **Tonal Layers** and **Soft Ambient Shadows**. 

1. **Base (Level 0):** The main background using the neutral hex.
2. **Cards (Level 1):** White surfaces with a 1px soft gray border or a very diffused shadow (Y: 4, Blur: 12, Opacity: 4%). This creates a "lifted" feel without visual clutter.
3. **Floating Actions (Level 2):** Sticky "Add to Cart" bars or navigation menus use a more pronounced shadow (Y: 8, Blur: 20, Opacity: 8%) to signify they sit above the scrollable content.
4. **Modals:** Use a 40% opacity black backdrop blur to maintain context while focusing the user on the task.

## Shapes
The shape language is "Soft-Modern." Elements use a **12px to 16px radius** (Level 2/Rounded) to feel approachable and high-end.

- **Standard Buttons & Cards:** 12px corner radius.
- **Input Fields:** 8px corner radius to maintain a slightly more structured look.
- **Search Bars:** Fully pill-shaped (rounded-xl) to distinguish the search utility from content cards.
- **Badges/Chips:** 4px radius for a crisp, organized appearance.

## Components

- **Primary Button:** High-contrast Emerald background, white Geist Medium text. 12px radius. On press, the color should darken by 10%.
- **Secondary Button:** Ghost style with a 1px border of the Secondary color. Used for "Add to Wishlist" or "View Details."
- **Product Card:** A compound component with a 1:1 aspect ratio image container, 12px padding for the text stack, and a subtle Level 1 elevation.
- **Quantity Selector:** A horizontal pill-shaped component with distinct plus/minus icons and a neutral background.
- **Input Fields:** 16px height for labels, 48px height for the input area. Uses a 1px border that turns Emerald on focus.
- **Status Chips:** Small, 4px rounded boxes. Green background (10% opacity) with Green text for "In Stock"; Red background (10% opacity) with Red text for "Out of Stock."
- **Bottom Sheet:** Used for filters and size selection. Includes a centered 4px handle at the top and 24px internal padding.