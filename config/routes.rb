# frozen_string_literal: true

# Administration, Taggar, and a tag's own page (#key in text links here)
# a handle may hold dots, so the format is taken only when it is html or json (gk_tags/t/kundkrav.json is REST); the
# parameter is not called key, which Redmine reads as an API key
get 'gk_tags/t/:handle(.:format)', to: 'gk_tags_tags#show', as: 'gk_tags_tag_page', constraints: { handle: %r{[^/]+?}, format: /html|json/ }
# Administration > Taggar > Typer (before the tags, so that types is never read as a tag's id)
resources :gk_tags_types, path: 'gk_tags/types', only: %i[index show new create edit update] do
  member do
    post :retire
  end
end
# One form saves everything on a tag (update)
resources :gk_tags_tags, path: 'gk_tags', only: %i[index edit update]
# Marks and focus, a person's own
get 'gk_tags/marks', to: 'gk_tags_personal#marks', as: 'gk_tags_marks'
post 'gk_tags/marks', to: 'gk_tags_personal#create_mark', as: 'gk_tags_create_mark'
post 'gk_tags/marks/:id', to: 'gk_tags_personal#update_mark', as: 'gk_tags_update_mark'
post 'gk_tags/marks/:id/delete', to: 'gk_tags_personal#delete_mark', as: 'gk_tags_delete_mark'
post 'issues/:issue_id/gk_tags/mark', to: 'gk_tags_personal#mark', as: 'gk_tags_mark'
post 'issues/:issue_id/gk_tags/unmark', to: 'gk_tags_personal#unmark', as: 'gk_tags_unmark'
# The note of one's own marking, changed from the popover its icon opens (JSON for the script)
patch 'gk_tags/markings/:id/note', to: 'gk_tags_personal#note', as: 'gk_tags_note'
get 'gk_tags/focus', to: 'gk_tags_personal#focus', as: 'gk_tags_focus'
get 'projects/:project_id/gk_tags/focus', to: 'gk_tags_personal#focus', as: 'gk_tags_project_focus'
post 'issues/:issue_id/gk_tags/focus', to: 'gk_tags_personal#focus_add', as: 'gk_tags_focus_add'
post 'issues/:issue_id/gk_tags/focus/remove', to: 'gk_tags_personal#focus_remove', as: 'gk_tags_focus_remove'
# No ranking, so no move; undo after a change, and the sharing box
post 'gk_tags/focus/undo', to: 'gk_tags_personal#focus_undo', as: 'gk_tags_focus_undo'
post 'gk_tags/focus/share', to: 'gk_tags_personal#focus_share', as: 'gk_tags_focus_share'
# The tab Taggar in a project's settings: the sidebar box's number per type
post 'projects/:project_id/gk_tags/sidebar', to: 'gk_tags_project_sidebar#update', as: 'project_gk_tags_sidebar'
