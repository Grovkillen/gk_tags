# GK Tags

GK Tags adds tags to Redmine issues and to objects that other GK plugins register. Tags start as free tags written by users, can be taken over and managed by administrators, and can be given types with rules and a hierarchy. The plugin also gives each user personal marks and a short list of issues in focus.

## Features

- A Tags field in the issue form: handles separated by spaces, with or without `#`. Writing a new handle creates a free tag, for users with the permission to create free tags.
- Tags on the issue page, a Tags filter and a Tags column in the issue list, and tag changes in the issue history.
- `#handle` in rendered text becomes a link to the tag's own page. Issue links such as `#123`, Markdown headings, links and code are left as they are.
- A tag lifecycle: free tags become established when enough people or objects use them. An administrator can make a tag managed with a name, a description and a marking (warning or alarm), change its handle (the old handle becomes an alias), add aliases (optionally per language), stop suggesting an alias, merge tags and retire or restore them. Nothing is deleted.
- Tag types: a type gives its tags a category of the shared palette (1 to 12), an icon and rules: one tag of the type per object, which kinds of objects the tags may be put on, which kinds of objects require a tag of the type, an optional namespace (for example `#ce:S16`), whether a search on a parent finds the children, and whether the same handle may be used under different parents. Types are retired, never removed.
- A tag hierarchy: a tag can be moved under a parent, and is then written with its path, for example `#parent/child`.
- Marks: personal marks on issues and notes, with a private note; the same mark can be on an issue several times with different notes. A mark can be shared, in which case whoever can see the issue sees the mark, but never the note. A My marks page and a Marked filter.
- Focus: a user puts the issues they are actively working on in focus, up to a configurable maximum. When the list is full, the user chooses which issue to replace, and the change can be undone. The My focus page shows the current focus, Earlier focus, and Focus in my group (what others have shared). An In focus filter in the issue list, and Focus in the project menu.
- Focus sharing: each user chooses who sees their current focus and their earlier focus. Those they share with only see the issues they may see themselves.
- Personal markings: marks and focus are two kinds of one mechanism. A kind sets whether a person has one tag or many, notes, a cap, the order, a history, who sees it and how it is shown; another plugin can register its own kind with `GkTags::Personal.register`, and a kind shown as pills is put and shown like marks.
- REST JSON for tags, a user's marks and the focus page.
- Permissions in the project module Tags: View tags, Change issues' tags, Create free tags, See focus events and Set the tags in the sidebar. Two OAuth scopes for the REST API: Tags in the administration, and Own marks and focus.

## Requirements

- Redmine 6.0.0 or later
- Ruby: the version your Redmine runs on
- PostgreSQL

This plugin is developed and tested on Windows 11 with PostgreSQL only. That is a deliberate choice made for the maintainer's own convenience: the production system and the whole toolchain run there, and supporting other platforms and databases would cost time without adding anything for our own use. The Ruby code avoids needless Windows or PostgreSQL specific constructs, so it may well run on Linux, but that is untested and not supported. Its migrations use PostgreSQL's own types, so PostgreSQL is required.

Required GK plugins:

- gk_core_stuff: the tag line in an issue's history and the tab Tags in a project's settings are registered in its registers; without it the tab is not shown and the line is Redmine's own. `#tag` in formatted text is linked through its shared pass for formatted text; with a gk_core_stuff that does not have that pass no tag in a text is linked. The marks on an issue stand in the issue's head right after the author line through its hook there (module more_view_hooks); without that hook they stand in the issue's tags section.
- gk_gui_stuff: the design language's primitives the plugin's pages are drawn with (pills, the category picker, the fold-out boxes, the row menu, the chooser with Add and the form's count of changes), the page Administration > Functions where the functions are switched on, and the Mark and Focus entries in the issue's menu. Without it the interface of GK Tags is closed: no menus, pages or API, nothing drawn on other pages, no patches, and nothing of the interface is registered in other plugins. The Tags field on issues and the rules of the tag types are closed with it, since the field is part of the issue form and of the API of issues. The same holds while the installed gk_gui_stuff is too old or is not active itself. The project module Tags, its permissions and the two OAuth scopes stay registered all the same, so a role or a project that is saved meanwhile keeps them; they open nothing while the pages are closed. The event kinds and the targets in gk_records stay registered too, so a change to a tag or a tag type that another plugin makes meanwhile is still written as an event, and the focus events stay hidden from those without the permission See focus events. The plugin's settings page then says which of the three it is, and the migrations run all the same, so the stored tags and settings stand untouched.

Optional GK plugins:

- gk_records: the switches for the plugin's functions Marks, Focus, Tags on other objects and the box Tags in the sidebar (its register of functions), events for a tag's lifecycle, the reason field and the visibility of people's names. Without it these functions are off and cannot be turned on, and there is no history; tags on issues, types and the administration still work.
- gk_people: focus sharing with people, groups and responsibilities (including "My manager"), tags on organizations and persons, and the tags in the record of processing. Without it focus is shared with user accounts only.
- gk_fields: translations of the names of managed tags.
- gk_icons: the type's icon and the icon picker.
- gk_compat: Redmine's color variables in Redmine 6.0 and 6.1.
- gk_scenarios: test scenarios for the plugin; no effect in production.

## Installation

The plugin directory must be named `gk_tags` (it is the plugin id).

1. Unpack the release package into Redmine's `plugins` directory, so that the plugin lives in `plugins/gk_tags/`.
2. Run the migrations from the Redmine root:

   ```
   bundle exec rake redmine:plugins:migrate RAILS_ENV=production
   ```

3. Restart Redmine.

To uninstall, roll back the migrations and then remove the `plugins/gk_tags/` directory:

```
bundle exec rake redmine:plugins:migrate NAME=gk_tags VERSION=0 RAILS_ENV=production
```

## Configuration

Administration > Plugins > Configure next to GK Tags:

- Shortest handle.
- Established after this many people, or this many objects.
- At most in focus.
- Earlier focus, number of issues and number of days.
- The manager's responsibility (used with gk_people to decide who "My manager" is).
- Waiting statuses: an issue in focus with one of these statuses is marked as waiting.

Tags and tag types are managed under Administration > Tags. Enable the project module Tags in each project and grant the permissions per role. Marks, Focus, Tags on other objects and the box Tags in the sidebar are declared in gk_records and switched on under Administration > Functions in gk_gui_stuff; all are off in a new installation.

## Usage

- Write tags in the Tags field when creating or editing an issue; they appear on the issue page and can be filtered and shown as a column in the issue list.
- Click a tag to open its page, which lists what is tagged with it.
- With Marks switched on, mark an issue from the issue's menu and find your marks under My marks.
- With Focus switched on, use the focus button on the issue and open My focus (or Focus in the project menu) to see your focus, your earlier focus and what others share with you.

## Changelog

See CHANGELOG.md.

## License

GPL-2.0-or-later, the same license as Redmine. Copyright (C) 2026 Jimmy Westberg. See the LICENSE file for the full text.
