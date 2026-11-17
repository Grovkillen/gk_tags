# frozen_string_literal: true

# The tab Taggar in a project's settings: how many tags per type the sidebar's box shows in the project before Visa
# alla. Empty or 0 follows the instance's number. Kept in the plugin's settings (sidebar_top_projects), per project id.
class GkTagsProjectSidebarController < ApplicationController
  include GkTags::Gate::Controller
  before_action :find_project_by_project_id, :authorize

  def update
    all = (GkTags.setting('sidebar_top_projects', {}) || {}).to_h.dup
    n = params[:sidebar_top].to_s.strip.to_i
    n.positive? ? all[@project.id.to_s] = [n, 100].min.to_s : all.delete(@project.id.to_s)
    Setting.plugin_gk_tags = Setting.plugin_gk_tags.to_h.merge('sidebar_top_projects' => all)
    flash[:notice] = l(:notice_successful_update)
    redirect_to settings_project_path(@project, tab: 'gk_tags_sidebar')
  end
end
