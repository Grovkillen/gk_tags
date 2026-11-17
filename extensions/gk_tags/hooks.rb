# frozen_string_literal: true

module GkTags
  # The tag field in the issue form, the tags and marks on the issue page, a mark on each note, and the
  # plugin's stylesheet
  class Hooks < Redmine::Hook::ViewListener
    include GkTags::Gate::Listener # silent without GK GUI Stuff (gate.rb)

    render_on :view_issues_form_details_bottom, partial: 'gk_tags_tags/issue_field'
    render_on :view_issues_show_details_bottom, partial: 'gk_tags_tags/issue_section'
    render_on :view_issues_history_journal_bottom, partial: 'gk_tags_tags/journal_mark'

    def view_layouts_base_html_head(_context = {})
      return '' unless GkTags.ready?

      safe_join([stylesheet_link_tag('gk_tags', plugin: 'gk_tags'), javascript_include_tag('gk_tags', plugin: 'gk_tags')])
    end

    # The marks in the issue's head, right after core's author line, through the hook GK Core Stuff adds there
    # (view_issues_show_author_after, module more_view_hooks); drawn by the server, nothing is moved in the page
    def view_issues_show_author_after(context = {})
      issue = context[:issue]
      return ''.html_safe unless self.class.head_marks? && self.class.marks?(issue)

      context[:hook_caller].render(partial: 'gk_tags_tags/head_marks', locals: { issue: issue, head: true })
    end

    # Whether the viewer sees marks on the issue: personal marking on the issue and a kind drawn as pills
    def self.marks?(issue)
      GkTags::Access.personal?(issue) && GkTags::Personal.with_surface(:pills).any?
    end

    # Whether the issue page drawn now calls the hook after the author line, asked of GK Core Stuff's public answer
    # (GkCoreStuff.hook?). Without GK Core Stuff, or with one that cannot answer, the marks stand
    # in the tags' section; the page is never searched for the author line.
    def self.head_marks?
      return false unless defined?(::GkCoreStuff) && ::GkCoreStuff.respond_to?(:hook?)

      ::GkCoreStuff.hook?(:view_issues_show_author_after, view: 'issues/show') == true
    rescue StandardError
      false
    end
  end
end
