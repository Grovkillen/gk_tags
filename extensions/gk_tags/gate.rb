# frozen_string_literal: true

module GkTags
  # The gate to GK GUI Stuff, which tags requires. It is open when GK GUI Stuff answers the gate's questions, its
  # base version (the version without a candidate's suffix) is the lowest one tags needs or later, and its own gate
  # is open; candidates of one base version are not told apart.
  #
  # A gate closes only the interface, never a protection. Closed, the gate closes what a person works with: the menus,
  # the pages, the REST API, the hooks (what tags draws on other pages), the core patches (patches.rb) and what tags
  # registers of its interface in other plugins' registers (menu rows, page data, personal pages, translations, the
  # record of processing, functions, appearance settings, the reason place); and its own registers answer nothing to
  # other plugins (not ready, no function or appearance setting on, no class made taggable, no issue put in focus).
  # The tag types' rules
  # (IssuePatch, issue_tags.rb) are closed with it: they test the field gk_tag_list, which is the plugin's own field
  # in the issue form and in the REST API of issues, so without the field there is nothing for them to test, and the
  # patch would open the field in REST and bulk edit while the pages are closed. It never closes:
  # * the project module gk_tags with its five permissions and the two OAuth scopes: init.rb registers them whatever
  #   the gate says. Core's role form lists only the permissions that are registered and Role#permissions= writes the
  #   whole list, and a project's modules are saved the same way, so a role or a project saved while they were away
  #   would lose them. With the gate closed they open nothing: the controllers answer 404 and the menus are gone.
  # * the targets (a tag, a type) and the event kinds in GK Records: init.rb registers them whatever the gate says.
  #   Lifecycle and TypeLifecycle (core.rb) never ask the gate and are called by other plugins and by scenario steps
  #   too, and GkRecords::Events.write refuses a target or a kind that is not registered, so the tag or type would be
  #   changed without a trace and the caller would get an error. The focus kinds carry the permission
  #   gk_tags_view_focus_events, and GK Records hides the events of a kind from those without its permission only
  #   while the kind is registered, so the events already written stay with the person.
  # Nothing else stands outside: tags has no core patch that denies, locks or hides. No issue is put in focus and no
  # class is made taggable while the gate is closed, so no focus event and no event of an object's tags is written
  # then; an event that a caller outside the pages writes (a tag's, a type's, a sharing's) is written as always, and
  # GK Records puts in its details that the gate was closed.
  # The settings page says the first thing that is not met in one line of core's own form (<p class="warning">) before
  # the About box; the migrations run all the same, so nothing is lost when GK GUI Stuff comes in. The extension files
  # are still loaded, so another plugin that asks defined?(::GkTags::X) finds an empty answer and leaves tags alone
  # instead of failing.

  # The lowest base version the gate opens for; IDENTITY.yml requires the same base and a test holds the two together
  GUI_STUFF_MIN = '1.05.000'

  #   GkTags.gui_closed -> nil when the gate is open; otherwise the first thing that is not met: :missing (no GK GUI
  #   Stuff), :old (it does not answer open?, or its base version is older than GUI_STUFF_MIN) or :inactive (its own
  #   gate is closed)
  def self.gui_closed
    return :missing unless defined?(::GkGuiStuff)
    return :old unless ::GkGuiStuff.respond_to?(:open?) && ::GkGuiStuff.respond_to?(:version_at_least?) &&
                       ::GkGuiStuff.version_at_least?(GUI_STUFF_MIN)
    return :inactive unless ::GkGuiStuff.open?

    nil
  rescue StandardError
    :missing
  end

  #   GkTags.gui? -> true when gui_closed has nothing to say
  def self.gui? = gui_closed.nil?

  module Gate
    # The hook methods a view or controller listener answers (view_*, controller_*, model_*). Redmine asks a listener
    # respond_to?(hook) once and keeps the answer (Redmine::Hook.hook_listeners), so a closed gate keeps every hook of
    # tags' listeners silent. A listener is registered as soon as its class is defined (Listener.inherited), so the
    # gate is in the listener and not in init.rb.
    HOOK = /\A(view|controller|model)_/

    module Listener
      def respond_to?(name, include_all = false)
        return false if HOOK.match?(name.to_s) && !GkTags.gui?

        super
      end
    end

    # Every tags controller (the pages and the REST API) is closed without GK GUI Stuff: core's 404. A plain
    # before_action, after the ones ApplicationController has (the session, the user, the language), so that the 404 is
    # drawn for the person and in the language of the request; before the controller's own (require_login and the like)
    module Controller
      def self.included(base)
        base.before_action :gk_tags_gate
      end

      private

      def gk_tags_gate
        render_404 unless GkTags.gui?
      end
    end
  end
end
