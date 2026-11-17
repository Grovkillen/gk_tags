# frozen_string_literal: true
# Depends on: gk_core_stuff and gk_gui_stuff 1.05.000 or later required; optional gk_records, gk_people, gk_fields,
# gk_icons, gk_compat, gk_scenarios. Without gk_gui_stuff the interface of tags is closed (GkTags.gui?, gate.rb): no
# menus, pages, API, hooks, patches or interface registrations in other plugins; the settings page says so, and the
# migrations run all the same. The project module, its permissions and the two OAuth scopes are registered whatever
# the gate says, so that a role or a project saved meanwhile keeps them, and so are the targets and event kinds in
# gk_records, so that a trace is written and the focus events stay behind their permission.

require_relative 'extensions/gk_tags/gate'
require_relative 'extensions/gk_tags/core'
require_relative 'extensions/gk_tags/types'
require_relative 'extensions/gk_tags/issue_tags'
require_relative 'extensions/gk_tags/personal_kinds'
require_relative 'extensions/gk_tags/personal'
require_relative 'extensions/gk_tags/focus_sharing'
require_relative 'extensions/gk_tags/text_links'
require_relative 'extensions/gk_tags/json'
require_relative 'extensions/gk_tags/hooks'
require_relative 'extensions/gk_tags/sidebar'
require_relative 'extensions/gk_tags/patches'

Redmine::Plugin.register :gk_tags do
  name        'GK Tags'
  author      'Jimmy Westberg'
  description 'Tags as a semantic layer: free and managed tags, aliases, tags on issues, marks and focus'
  version     '1.00.000'
  requires_redmine version_or_higher: '6.0.0'

  settings default: { 'min_length' => '2', 'establish_users' => '3', 'establish_objects' => '10', 'focus_max' => '3',
                      'waiting_status_ids' => [], 'focus_history_issues' => '10', 'focus_history_days' => '30',
                      'manager_responsibility' => '', 'sidebar_top_projects' => {} },
           partial: 'settings/gk_tags_settings'

  # The project module and the permissions are registered whatever the gate says (gate.rb). Core's role form lists
  # only the permissions that are registered and Role#permissions= writes the whole list, and a project's module list
  # is saved the same way, so a role or a project saved while they were away would lose them. With the gate closed
  # they open nothing: the controllers answer 404 and the menus are gone.
  # plugins/tags ### taggables: see the tags, change an issue's tags, create a free tag by writing a new handle
  project_module :gk_tags do
    permission :gk_tags_view, {}, read: true
    permission :gk_tags_tag, {}
    permission :gk_tags_create_free, {}
    # Who may see the focus events in an issue's events; no role has it by default, so a person's focus history stays
    # with the person and those it is shared with
    permission :gk_tags_view_focus_events, {}
    # How many tags per type the sidebar's box shows in the project before Visa alla (the tab Taggar in its settings)
    permission :gk_tags_sidebar_top, { gk_tags_project_sidebar: %i[update] }, require: :member
  end
  # OAuth scopes only (a role grants nothing with them): the administrators' tag list and one's own marks and focus
  # over REST; who may is still the admin flag and the login
  permission :gk_tags_api_admin, {}, require: :loggedin
  permission :gk_tags_api_personal, {}, require: :loggedin

  menu :admin_menu, :gk_tags_tags, { controller: 'gk_tags_tags', action: 'index' },
       caption: :label_gk_tags_tags, icon: 'bookmarked', html: { class: 'icon' }, if: proc { GkTags.gui? }
  menu :project_menu, :gk_tags_focus, { controller: 'gk_tags_personal', action: 'focus' },
       param: :project_id, caption: :label_gk_tags_focus_page, after: :activity,
       if: proc { |p| GkTags.gui? && GkTags.ready? && GkTags.feature?('tags.focus') && p.module_enabled?(:gk_tags) }
end

# The traces and what guards them, whatever the gate says (gate.rb): the targets and the event kinds in records
# (records loads before this, alphabetically). GkTags::Lifecycle and GkTags::TypeLifecycle are called by other
# plugins and by scenario steps too, not only from the pages of tags, and GkRecords::Events.write refuses a target or
# a kind that is not registered; and an event kind's permission hides its events only while the kind is registered.
if defined?(GkRecords)
  # A tag's lifecycle as events on the tag; only administrators see a tag's history, like the page
  GkRecords::Targets.register(GkTags::OWN_TARGET, model: 'GkTagsTag',
                               visible: ->(_t, user) { user.admin? }, editable: ->(_t, user) { user.admin? },
                               label: ->(t) { "##{t.key}" }, url: ->(t) { { controller: 'gk_tags_tags', action: 'edit', id: t.id } })
  GkTags::OWN_KINDS.each do |k|
    GkRecords::Kinds.register_event(k, plugin: :gk_tags, label_key: "label_gk_tags_event_#{k}", target: GkTags::OWN_TARGET)
  end
  # A type's own events, seen by administrators like the page
  GkRecords::Targets.register(GkTags::TYPE_TARGET, model: 'GkTagsType',
                               visible: ->(_t, user) { user.admin? }, editable: ->(_t, user) { user.admin? },
                               label: ->(t) { t.name }, url: ->(t) { { controller: 'gk_tags_types', action: 'edit', id: t.id } })
  GkTags::TYPE_KINDS.each do |k|
    GkRecords::Kinds.register_event(k, plugin: :gk_tags, label_key: "label_gk_tags_event_#{k}", target: GkTags::TYPE_TARGET)
  end
  # The tags of an object without a journal changed, on the object (an organization, a person)
  GkRecords::Kinds.register_event(GkTags::OBJECT_KIND, plugin: :gk_tags, label_key: "label_gk_tags_event_#{GkTags::OBJECT_KIND}")
  # Focus put in and taken out as events on the issue (the target workflow_rules registers), sharing and
  # taking back as events on the person's user (people registers it). The permission on the focus kinds is what
  # keeps a person's focus events from those without it, so the kinds are registered also while the gate is closed.
  GkTags::Focus::EVENT_KINDS.each do |k|
    GkRecords::Kinds.register_event(k, plugin: :gk_tags, label_key: "label_gk_tags_event_#{k}", target: 'issue', person_fields: %w[user],
                                        permission: :gk_tags_view_focus_events)
  end
  GkTags::FocusSharing::EVENT_KINDS.each do |k|
    GkRecords::Kinds.register_event(k, plugin: :gk_tags, label_key: "label_gk_tags_event_#{k}", target: 'user', person_fields: %w[recipient])
  end
end

# Everything below is the interface of tags, and only with GK GUI Stuff (GkTags.gui?, gate.rb). Without it nothing
# is hooked or patched and nothing of the interface is registered in other plugins; the settings page says so and the
# migrations run all the same. The tag types' rules (IssuePatch) are here too: they test the field gk_tag_list, which
# is the plugin's own field in the form and in the REST API of issues.
if GkTags.gui?
  Redmine::Hook.add_listener(GkTags::Hooks) unless Redmine::Hook.listeners.any?(GkTags::Hooks)
  Redmine::Hook.add_listener(GkTags::SidebarHooks) unless Redmine::Hook.listeners.any?(GkTags::SidebarHooks)
  # Core patches (extensions/gk_tags/patches.rb): the helpers in every view, the tag field on Issue, the filters and
  # column on IssueQuery, and #tag in rendered text; applied here and again on every reload
  GkTags::Patches.apply!
  # The tag line in the history and the tab Taggar in a project's settings, in core_stuff's registers (core_stuff loads
  # before tags)
  Rails.configuration.after_initialize do
    GkTags::HistoryLine.register!
    GkTags::SidebarProjectTab.register!
  end

  # Rows in the issue's menu: mark it, put it in focus (gui_stuff loads before this)
  GkGuiStuff::Menu.register('tg_mark', section: :do, context: :issue, plugin: :gk_tags, kind: :post, order: 70, placement: :menu,
                                        icon: 'bookmark-add', label: :button_gk_tags_mark,
                                        condition: ->(page) { GkTags.feature?('tags.marks') && (i = Issue.find_by(id: page[:id])) && GkTags::Access.personal?(i) },
                                        href: ->(page) { Rails.application.routes.url_helpers.gk_tags_mark_path(page[:id]) })
  # One row for focus, out by default, whose label, tooltip, state and address follow the issue
  # (GkTags::FocusButton). Kind action: the script posts the address, or, when the list is full, shows the issues in
  # focus to replace one of them in one click.
  GkGuiStuff::Menu.register('tg_focus', section: :state, context: :issue, plugin: :gk_tags, kind: :action, action: 'tg_focus_choose',
                                         order: 71, placement: :out, name: :label_gk_tags_focus_button,
                                         icon: ->(_page) { 'fav' },
                                         label: ->(page) { GkTags::FocusButton.label(page) },
                                         title: ->(page) { GkTags::FocusButton.title(page) },
                                         active: ->(page) { GkTags::FocusButton.state(page) == :on },
                                         condition: ->(page) { GkTags::FocusButton.shown?(page) },
                                         href: ->(page) { GkTags::FocusButton.href(page) })
  # What the focus button's script needs on the issue page, with the page (gui_stuff's PageData): only on an issue
  # page, only when the function is on
  GkGuiStuff::PageData.register('tg_focus', plugin: :gk_tags) do |ctx|
    c = ctx[:controller]
    next nil unless c.is_a?(::IssuesController) && c.action_name == 'show' && GkTags.ready? && GkTags.feature?('tags.focus')

    issue = c.instance_variable_get(:@issue)
    next nil unless issue&.persisted? && GkTags::Access.personal?(issue)

    GkTags::FocusButton.data(issue, User.current)
  end
  # The tags' names in fields' one place for translations
  if defined?(GkFields::Translations) && GkFields::Translations.respond_to?(:register_type)
    GkFields::Translations.register_type('GkTagsTag', attrs: %w[name description], label: -> { I18n.t(:label_gk_tags_tags) },
                                                      records: -> { GkTagsTag.global.where(status: 'managed').order(:key) },
                                                      off_controllers: %w[gk_tags_tags])
    GkFields::Translations.register_type('GkTagsType', attrs: %w[name description], label: -> { I18n.t(:label_gk_tags_types) },
                                                       records: -> { GkTagsType.sorted }, off_controllers: %w[gk_tags_types])
  end
  # The record of processing: taggings name who tagged, marked and focused
  if defined?(GkPeople::Processing)
    GkPeople::Processing.declare(:gk_tags_taggings, category: 'work', plugin: :gk_tags)
    # Who a person shares her focus with; target_id is a user when kind is user
    GkPeople::Processing.declare(:gk_tags_focus_shares, category: 'work', plugin: :gk_tags)
    if GkPeople::Processing.respond_to?(:declare_ref)
      GkPeople::Processing.declare_ref(:gk_tags_focus_shares, type_column: :kind, type_value: 'user', id_column: :target_id, kind: :user)
      # A person tagged (people registers its persons as taggable)
      GkPeople::Processing.declare_ref(:gk_tags_taggings, type_column: :taggable_type, type_value: 'GkPeoplePerson', id_column: :taggable_id, kind: :person)
    end
  end
  # Issues are taggable by tags itself (key issue, used by allowed_on and required_for); other plugins register theirs
  # with GkTags::Taggables.register (people: organization, person) and get GkTags::Taggable
  GkTags::Taggables.register('Issue', key: 'issue', label: :label_issue,
                                       view: ->(i, u) { GkTags::Access.view?(i, u) }, tag: ->(i, u) { GkTags::Access.tag?(i, u) },
                                       url: ->(i) { { controller: 'issues', action: 'show', id: i.id } }, title: ->(i) { "##{i.id} #{i.subject}" })
  # init.rb runs again on every reload, and after_initialize then runs at once: the classes registered are attached anew
  Rails.configuration.after_initialize { GkTags::Taggables.attach_all! }
  # Declared functions in records' register: off for a new installation, switched on under Administration >
  # Funktioner
  Rails.configuration.after_initialize do
    if defined?(::GkRecords::Features) && ::GkRecords::Features.respond_to?(:register)
      ::GkRecords::Features.register('tags.marks', plugin: :gk_tags,
                                                    label: :label_gk_feature_tags_marks, help: :text_gk_feature_tags_marks)
      ::GkRecords::Features.register('tags.focus', plugin: :gk_tags,
                                                    label: :label_gk_feature_tags_focus, help: :text_gk_feature_tags_focus)
      # Tags on the objects other plugins register (organizations and persons in people)
      ::GkRecords::Features.register('tags.objects', plugin: :gk_tags,
                                                      label: :label_gk_feature_tags_objects, help: :text_gk_feature_tags_objects)
    end
    # The box Taggar in the sidebar of the issue list and of people's lists (GkTags::Sidebar), with its two numbers as
    # values (a function before, so the page says it moved), and a mark's note written out in its pill: appearance
    # settings in records' register, off for a new installation
    if defined?(::GkRecords::AppearanceSettings)
      ::GkRecords::AppearanceSettings.register(GkTags::Sidebar::FEATURE, plugin: :gk_tags, group: :lists, moved_from: :features, anonymous: true,
                                                                         label: :label_gk_tags_appearance_sidebar, help: :text_gk_tags_appearance_sidebar,
                                                                         values: { 'sidebar_limit' => { kind: :number, default: 15, min: 1, max: 1000, step: 1,
                                                                                                        label: :field_gk_tags_sidebar_limit, help: :text_gk_tags_sidebar_limit },
                                                                                   'sidebar_top' => { kind: :number, default: 5, min: 1, max: 100, step: 1,
                                                                                                      label: :field_gk_tags_sidebar_top, help: :text_gk_tags_sidebar_top } })
      ::GkRecords::AppearanceSettings.register(GkTags::NOTE_TEXT, plugin: :gk_tags, group: :issue, preview: 'gk_tags_appearance/previews/note_text',
                                                                  label: :label_gk_tags_appearance_note_text, help: :text_gk_tags_appearance_note_text)
    end
  end
  # The reason places in gk_records (records may load after this plugin)
  Rails.configuration.after_initialize do
    if defined?(::GkRecords::Reasons)
      ::GkRecords::Reasons.register('tags.lifecycle', plugin: :gk_tags, label: :label_gk_reason_tags_lifecycle, default: :optional, admin: true)
    end
  end
  # The person's own pages (My marks, My focus) are declared once in gui_stuff's register (GkGuiStuff::Personal), which
  # places them by core's version
  Rails.configuration.after_initialize do
    ::GkGuiStuff::Personal.register('tags.marks', plugin: :gk_tags, label: :label_gk_tags_my_marks, order: 50,
                                      url: { controller: 'gk_tags_personal', action: 'marks' }, if: ->(u) { GkTags.ready? && GkTags.feature?('tags.marks') })
    ::GkGuiStuff::Personal.register('tags.focus', plugin: :gk_tags, label: :label_gk_tags_my_focus, order: 51, icon: 'fav',
                                      url: { controller: 'gk_tags_personal', action: 'focus' }, count: ->(u) { GkTags::Focus.count(u) }, waits: false,
                                      if: ->(_u) { GkTags.ready? && GkTags.feature?('tags.focus') })
  end
end
