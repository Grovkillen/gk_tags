# frozen_string_literal: true

# A person's own marks and focus (plugins/tags ### marks, ### focus). Marks: mark and unmark an issue or a note,
# the page Mina märken (another person's shared marks with user_id), and one's own marks (new, name, colour,
# shared). Focus: put an issue in focus (naming the issue to replace when the list is full), take it out, undo, share
# it, and the page Fokus with its tabs. Only about oneself: nobody marks or focuses for someone else.
class GkTagsPersonalController < ApplicationController
  include GkTags::Gate::Controller
  accept_api_auth :marks, :focus
  before_action :require_login
  # REST: an OAuth token reaches marks and focus only with the scope gk_tags_api_personal (who may stays the login)
  before_action :require_personal_scope, only: %i[marks focus]
  # Declared functions: a page whose function is off is not there
  before_action -> { render_404 unless GkTags.feature?('tags.marks') }, only: %i[marks create_mark update_mark delete_mark]
  # Putting and taking off: any personal kind drawn as pills that is on (GkTags::Personal)
  before_action -> { render_404 if GkTags::Personal.with_surface(:pills).empty? }, only: %i[mark unmark note]
  before_action -> { render_404 unless GkTags.feature?('tags.focus') }, only: %i[focus focus_add focus_remove focus_undo focus_share]
  before_action :find_issue, only: %i[mark unmark focus_add focus_remove]
  helper :gk_tags

  # Mina märken, or someone else's shared marks
  def marks
    @owner = params[:user_id].present? ? User.active.find_by(id: params[:user_id]) : User.current
    return render_404 unless @owner

    @own = @owner == User.current
    @marks = @own ? GkTags::Marks.of(User.current) : GkTagsTag.where(kind: 'mark', owner_id: @owner.id, shared: true).to_a
    @taggings = GkTags::Marks.listing(@owner, User.current, mark_id: params[:mark_id])
    return unless api_request?

    render json: { marks: @taggings.map { |t| GkTags::Json.mark(t, User.current) } }
  end

  # Mark an issue (or one of its notes with journal_id) with one of one's own personal tags of a kind drawn as pills (a
  # mark, or a kind another plugin registered), with an optional note; without mark_id the default mark
  def mark
    object = params[:journal_id].present? ? @issue.journals.find_by(id: params[:journal_id]) : @issue
    return render_404 unless object

    kinds = GkTags::Personal.with_surface(:pills).map(&:key)
    tag = params[:mark_id].present? ? GkTagsTag.find_by(id: params[:mark_id], kind: kinds, owner_id: User.current.id) : nil
    if tag then GkTags::Personal.put(tag, object, User.current, note: params[:note])
    elsif kinds.include?('mark') then GkTags::Marks.mark(object, User.current, nil, note: params[:note])
    end
    redirect_back_or_default issue_path(@issue)
  end

  def unmark
    kinds = GkTags::Personal.with_surface(:pills).map(&:key)
    t = GkTagsTagging.active.joins(:tag).find_by(id: params[:tagging_id], gk_tags_tags: { kind: kinds, owner_id: User.current.id })
    GkTags::Personal.remove(t, User.current) if t
    redirect_back_or_default issue_path(@issue)
  end

  # Change the note of one's own marking (PATCH from the popover the note's icon opens): only her own, of a kind drawn as
  # pills with notes, on an issue she may still mark. An empty note takes it away. Refused when the same mark sits on
  # the same object with that note already, since two equal markings never exist. The script reads the error as JSON.
  def note
    kinds = GkTags::Personal.with_surface(:pills).map(&:key)
    t = GkTagsTagging.active.joins(:tag).find_by(id: params[:id], gk_tags_tags: { kind: kinds, owner_id: User.current.id })
    issue = t&.issue
    return note_answer(issue, :not_found, l(:error_gk_tags_note_gone)) unless issue && GkTags::Access.personal?(issue)

    ok, why = GkTags::Personal.renote(t, User.current, params[:note])
    return note_answer(issue, :unprocessable_entity, l("error_gk_tags_note_#{why}")) unless ok

    note_answer(issue, :ok, nil)
  end

  def create_mark
    m = GkTags::Marks.create(User.current, params[:name], category: params[:category], shared: params[:shared] == '1')
    flash[(m.persisted? ? :notice : :error)] = m.persisted? ? l(:notice_successful_create) : m.errors.full_messages.join(', ')
    redirect_to gk_tags_marks_path
  end

  def update_mark
    m = GkTagsTag.find_by(id: params[:id], kind: 'mark', owner_id: User.current.id) or return render_404
    m.update(name: params[:name].to_s.strip.first(255).presence || m.name, category: params.key?(:category) ? GkTags.category(params[:category]) : m.category,
             shared: params[:shared] == '1', status: params[:retire] == '1' ? 'retired' : m.status)
    redirect_to gk_tags_marks_path
  end

  # One's own mark taken away: off every issue and note it is on, and no longer offered. The default mark stays, since
  # it is what Märk uses without a choice.
  def delete_mark
    m = GkTagsTag.find_by(id: params[:id], kind: 'mark', owner_id: User.current.id) or return render_404
    return render_403 if m.key == 'highlight'

    GkTagsTag.transaction do
      GkTagsTagging.active.where(tag_id: m.id).find_each { |t| t.remove!(User.current) }
      m.update!(status: 'retired')
    end
    flash[:notice] = l(:notice_successful_delete)
    redirect_to gk_tags_marks_path
  end

  # Fokus: the tabs Mitt fokus (one's own list and the sharing box), Tidigare fokus (one's own history in two modes)
  # and Fokus i min grupp (what others shared with the viewer; in a project only its members). REST gives one's own
  # focus and the focus shared with the viewer.
  TABS = %w[mine history group].freeze

  def focus
    @project = params[:project_id].present? ? Project.visible.find_by(identifier: params[:project_id]) || Project.visible.find_by(id: params[:project_id]) : nil
    return render_404 if params[:project_id].present? && !@project

    if api_request?
      rows = [{ user: User.current, items: GkTags::Focus.items(User.current) }] + group_board
      return render(json: { focus: rows.reject { |row| row[:items].empty? }.map { |row| GkTags::Json.focus_row(row) } })
    end
    @tab = TABS.include?(params[:tab].to_s) ? params[:tab].to_s : 'mine'
    case @tab
    when 'mine'
      @items = GkTags::Focus.items(User.current)
      @shares = GkTags::FocusSharing.rows(User.current)
      @choices = GkTags::FocusSharing.choices(User.current)
    when 'history'
      @mode = GkTags::FocusHistory::MODES.include?(params[:mode].to_s) ? params[:mode].to_s : 'issues'
      @n = params[:n].to_i.positive? ? [params[:n].to_i, 1000].min : GkTags::FocusHistory.default_n(@mode)
      @rows = GkTags::FocusHistory.rows(User.current, mode: @mode, n: @n)
    else
      @board = group_board
    end
  end

  # Put the issue in focus; when the list is full, replace=<issue id> names the one it takes the place of
  def focus_add
    result, old = GkTags::Focus.add(@issue, User.current, replace: params[:replace].presence)
    max = GkTags::Focus.max
    case result
    when :added
      notice_with_undo(l(:notice_gk_tags_focus_added, id: @issue.id, n: GkTags::Focus.count(User.current), max: max), drop: @issue.id)
    when :replaced
      notice_with_undo(l(:notice_gk_tags_focus_replaced, id: @issue.id, old: old, max: max), drop: @issue.id, restore: old)
    when :full
      flash[:warning] = l(:notice_gk_tags_focus_full, max: max)
    else
      flash[:notice] = l("notice_gk_tags_focus_#{result}", max: max)
    end
    redirect_back_or_default issue_path(@issue)
  end

  def focus_remove
    notice_with_undo(l(:notice_gk_tags_focus_removed, id: @issue.id), restore: @issue.id) if GkTags::Focus.remove(@issue, User.current)
    redirect_back_or_default issue_path(@issue)
  end

  # Ångra: back to the state before the last add, replace or remove (drop: put in then, restore: taken out then)
  def focus_undo
    done = GkTags::Focus.undo(User.current, drop: params[:drop].presence, restore: params[:restore].presence)
    flash[(done ? :notice : :warning)] = l(done ? :notice_gk_tags_focus_undone : :notice_gk_tags_focus_not_undone)
    redirect_back_or_default gk_tags_focus_path
  end

  # The sharing box: the whole choice for both scopes at once
  def focus_share
    allowed = GkTags::FocusSharing.choices(User.current)
    wanted = GkTags::FocusSharing::SCOPES.index_with do |scope|
      p = params.dig(:share, scope) || {}
      list = []
      list << ['manager', nil] if p[:manager] == '1'
      %w[group people_group user].each do |kind|
        ok = allowed[kind].map(&:last)
        list += Array(p[:"#{kind}_ids"]).map(&:to_i).select { |id| ok.include?(id) }.map { |id| [kind, id] }
      end
      list
    end
    flash[:notice] = l(:notice_successful_update) if GkTags::FocusSharing.save(User.current, wanted)
    redirect_to gk_tags_focus_path(tab: 'mine')
  end

  private

  # The answer to a changed note: JSON for the script (no content when it is saved, else { error: }), a redirect back
  # with the message for anything else
  def note_answer(issue, status, error)
    if request.xhr? || request.format.json?
      return head(:no_content) if status == :ok

      return render(json: { error: error }, status: status)
    end
    flash[:error] = error if error
    redirect_back_or_default(issue ? issue_path(issue) : home_path)
  end

  # The notice after a change of focus says what happened and has Ångra: a link posting to focus_undo,
  # back to the page one came from
  def notice_with_undo(text, drop: nil, restore: nil)
    back = params[:back_url].presence || issue_path(@issue)
    link = view_context.link_to(l(:button_gk_tags_undo), gk_tags_focus_undo_path(drop: drop, restore: restore, back_url: back),
                                method: :post, class: 'gk-tags-undo')
    flash[:notice] = "#{ERB::Util.html_escape(text)} #{link}"
  end

  # Fokus i min grupp and REST: others whose current focus is shared with the viewer, people records lets her see
  def group_board
    GkTags::Focus.board(User.current, project: @project).select { |row| GkTags::Json.user_visible?(row[:user]) }
  end

  # True without a token or without compat
  def require_personal_scope
    render_403 unless !gk_compat_shim?(:scope_allows?) || ::GkCompat.call(:scope_allows?, User.current, :gk_tags_api_personal)
  end

  # gk_compat is there and has the shim for the running series (an older gk_compat has no scope check)
  def gk_compat_shim?(name)
    defined?(::GkCompat) && ::GkCompat.respond_to?(:used) && ::GkCompat.used.shims.key?(name)
  end

  def find_issue
    @issue = Issue.find_by(id: params[:issue_id])
    return render_404 unless @issue
    return deny_access unless GkTags::Access.personal?(@issue)

    @project = @issue.project
  end
end
