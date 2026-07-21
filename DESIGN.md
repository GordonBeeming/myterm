---
name: MyTerm
description: A quiet native macOS workspace for terminals and browser tabs.
spacing:
  xs: "4px"
  sm: "6px"
  md: "8px"
  sidebar: "240px"
components:
  tab-row:
    height: "26px"
    padding: "6px 8px"
  tab:
    width: "112px"
  sidebar:
    width: "240px"
---

# Design System: MyTerm

## Overview

**Creative North Star: "The Native Workbench"**

MyTerm should feel like a dependable part of macOS: dense, direct, and quiet enough to disappear while work is happening. The hierarchy comes from familiar system structure—a title-only source list, a compact tab row, and an uninterrupted working surface—not from decoration.

The app stays deliberately narrow in scope. It should never resemble an agent dashboard, a novelty terminal, or a web app wrapped in desktop chrome.

**Key Characteristics:**

- Native system controls and behavior
- Compact, readable density
- Large uninterrupted terminal and browser surfaces
- Clear focus and keyboard paths
- No ornamental status or motion

## Colors

MyTerm uses macOS semantic colors and materials so contrast, selection, and appearance follow the active system theme. Terminal colors belong to the terminal profile and rendered content rather than the surrounding app chrome.

**The System Owns the Palette Rule.** Do not freeze native backgrounds, labels, separators, focus rings, or selection colors into custom hex values.

## Typography

**Display Font:** macOS system UI
**Body Font:** macOS system UI
**Label/Mono Font:** the terminal engine's monospaced terminal font

**Character:** Interface text is familiar and restrained. Monospaced type is reserved for terminal content; workspace titles, tabs, menus, and browser controls remain native system text.

### Hierarchy

- **Title:** Native navigation-title styling for the app and workspace rail.
- **Body:** Native control and field styling for workspace names and browser addresses.
- **Label:** Small native control sizing for tabs and compact actions.
- **Mono:** SwiftTerm's terminal typography, controlled by the terminal surface rather than SwiftUI chrome.

**The Terminal Owns Mono Rule.** Do not spread monospaced type into navigation or general controls to make the app look more technical.

## Elevation

MyTerm is flat by default. Depth comes from macOS window materials, source-list selection, dividers, splitters, and control states; the app adds no custom shadows.

**The Working Surface Rule.** Terminal and browser content should remain visually dominant, with chrome separated by structure rather than floating cards.

## Components

### Workspace Sidebar

- **Width:** 220–260 pt, ideally 240 pt.
- **Rows:** One editable title line only, using native source-list selection.
- **Actions:** Compact plus and minus icons at the bottom, with tooltips and accessibility labels.

### Tab Strip

- **Height:** A 26 pt control row with 6 pt vertical and 8 pt horizontal padding.
- **Tabs:** Native small bordered controls, 112–160 pt wide, with a close control on the selected tab.
- **Overflow:** Horizontal scrolling with the active tab kept visible. The add-tab menu stays fixed.

### Terminal Pane

- **Surface:** SwiftTerm fills the available pane without an inset card or decorative border.
- **Splits:** Native draggable splitters. Each pane has one quiet overflow menu for split and close actions.
- **Focus:** Clicking a pane makes it the target for split and close commands.

### Browser Tab

- **Toolbar:** Back, forward, reload, and one rounded address field in a compact horizontal row.
- **Surface:** WKWebView fills the remaining content area.
- **Behavior:** Browser tabs do not split in the first release.

### Commands

- **Visible path:** Toolbar, contextual menu, or local action button for every frequent task.
- **Keyboard path:** Native menu commands for workspace creation, terminal and browser tabs, splits, close, and sidebar visibility.

## Do's and Don'ts

### Do:

- **Do** keep workspaces scannable by title alone.
- **Do** use native macOS controls, semantic appearance, focus, menus, accessibility, and splitters.
- **Do** keep the tab row compact at 26 pt and scroll it when tabs exceed the available width.
- **Do** preserve a large, uninterrupted content surface.
- **Do** provide both a visible route and a keyboard route for frequent actions.
- **Do** make visible focus and VoiceOver labels part of the component contract.

### Don't:

- **Don't** copy cmux's notifications, agent status, colored workspace metadata, or other features outside the requested workflow.
- **Don't** use decorative terminal chrome, novelty controls, or motion that interrupts focused work.
- **Don't** build terminal rendering on web technology when a native implementation is available.
- **Don't** turn workspaces, tabs, or terminal panes into floating cards.
- **Don't** use custom fixed colors where macOS already provides an adaptive semantic role.
- **Don't** let browser controls or navigation chrome compete with the active terminal or page.
