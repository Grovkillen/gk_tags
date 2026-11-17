# frozen_string_literal: true

module GkTags
  # Core patches, all applied from here; the modules stay beside the code they serve:
  # * Issue (IssuePatch, issue_tags.rb): the field gk_tag_list as a safe attribute, its validation and the journal
  #   detail before save; core's safe_attributes, validate and before_save.
  # * Issue#gk_tags (IssueColumnValue, included): the column's value as text (CSV, PDF).
  # * IssueQuery#initialize_available_filters, #available_columns and #issues (IssueQueryPatch): the filters, the
  #   column, and the tags of the page's issues read in one go when the column is shown.
  # * QueriesHelper#column_value (ColumnPills, issue_tags.rb): the column in the list as the tags' pills; every other
  #   column is core's.
  # * No patch on textilizable: #tag in formatted text is linked in the runs of text GK Core Stuff's
  #   formatting_processors hands, where TextLinks::Processor is registered as this plugin's text processor
  #   (text_links.rb).
  # * GkTagsHelper in ActionView::Base: every view class inherits from it, so core's issue page and every registered
  #   object's page have the helpers; every name in the module carries the gk_tags_ prefix.
  # The tag line in the history and the tab Taggar in a project's settings are no patches: they are registered in
  # core_stuff's registers journal_detail and project_settings_tab (HistoryLine, SidebarProjectTab).
  # Applied directly from init.rb, which Redmine runs inside to_prepare at start and again after every reload in
  # development mode; every prepend and include is guarded, so a reload never adds a module twice.
  module Patches
    module_function

    def apply!
      return nil unless GkTags.gui? # no core patch without GK GUI Stuff (gate.rb)

      ActionView::Base.include(::GkTagsHelper) unless ActionView::Base.include?(::GkTagsHelper)
      ::Issue.prepend(IssuePatch) unless ::Issue < IssuePatch
      ::Issue.include(IssueColumnValue) unless ::Issue < IssueColumnValue
      ::IssueQuery.prepend(IssueQueryPatch) unless ::IssueQuery < IssueQueryPatch
      ::QueriesHelper.prepend(ColumnPills) unless ::QueriesHelper < ColumnPills
      # #tag in formatted text, through GK Core Stuff's pass; again on a reload replaces
      ::GkCoreStuff::FormattingProcessors.register(:gk_tags, text: TextLinks::Processor) if defined?(::GkCoreStuff::FormattingProcessors)
    end
  end
end
