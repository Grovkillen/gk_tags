# frozen_string_literal: true

# Tags: the tag's own page (anyone logged in; the issues the viewer may see), the list for the tag field (JSON), and
# Administration, Taggar (administrators): the lifecycle, a name, description and colour, a new handle (the old one
# becomes an alias), aliases, merging and retiring (plugins/tags ### admin, ### identity), each box of the page
# saved on its own with its reason. The same actions answer .json where they list (core's REST setting).
class GkTagsTagsController < ApplicationController
  include GkTags::Gate::Controller
  layout 'admin', except: [:show]
  self.main_menu = false
  accept_api_auth :index, :show
  before_action :require_admin, except: %i[index show]
  before_action :require_admin_scope, only: %i[index]
  before_action :find_tag, except: %i[index show]
  helper :gk_tags

  # What each box of the edit page sends under tag[...], with box=<key>: the box Taggen and the aliases
  # each with its own Save, and each action (a new handle, a new alias, making it managed, merge, retire or restore)
  # its own form in its popover box. A box saves only its own keys.
  BOXES = {
    'tag' => [:name, :description, :marking, :type_id, :parent, :reason],
    'aliases' => [:aliases_shown, { deprecated_alias_ids: [] }],
    'rename' => [:key, :reason],
    'alias' => [:alias_handle, :alias_language, :reason],
    'promote' => [:promote, :name, :description, :marking, :reason],
    'merge' => [:into, :reason],
    'retire' => [:retire, :reason]
  }.freeze
  # The statuses from which the action Gör administrerad makes a tag managed (a retired one is then in use again)
  PROMOTABLE = %w[free established retired].freeze

  def index
    scope = GkTagsTag.global
    scope = scope.where(status: params[:status]) if GkTags::STATUSES.include?(params[:status].to_s)
    @types = GkTags::Types.all
    if params[:type].present?
      @type = GkTags::Types.find(params[:type])
      scope = @type&.free? ? scope.where(type_id: [nil, @type.id]) : scope.where(type_id: @type&.id || 0)
    end
    @tags = scope.includes(:aliases, :merged_into, :type, :parent).sorted.to_a
    @counts = GkTagsTagging.active.where(tag_id: @tags.map(&:id)).group(:tag_id).count
    return render(json: { tags: @tags.map { |t| GkTags::Json.tag(t, @counts[t.id].to_i) } }) if api_request?

    GkTags.translated { render }
  end

  # The tag's page: what it is, its aliases and the issues with it the viewer may see
  def show
    # only for whoever may see tags somewhere (a 401 or the login page for someone not logged in, as core)
    return deny_access unless User.current.allowed_to?(:gk_tags_view, nil, global: true)

    # A tag whose written form is not its key (ns:value, a path) is linked by its id
    @tag = params[:tag_id].present? ? GkTags.follow_merged(GkTagsTag.global.find_by(id: params[:tag_id].to_i)) : GkTags.resolve(params[:handle])
    return render_404 unless @tag

    # with the tags merged into it and, where the type inherits, its descendants (### hierarchy)
    @search_ids = GkTags::Hierarchy.search_ids([@tag])
    ids = GkTagsTagging.active.where(tag_id: @search_ids, taggable_type: 'Issue').pluck(:taggable_id).uniq
    @issues = Issue.visible.where(id: ids).includes(:project, :status, :tracker).order(updated_on: :desc).limit(200).to_a
    @objects = other_objects(@search_ids)
    @children = @tag.children.usable.sorted.to_a
    if api_request?
      return render(json: GkTags::Json.tag(@tag, ids.size).merge(issues: @issues.map(&:id), descendants: @search_ids - @tag.self_and_merged_ids,
                                                                  objects: @objects.flat_map { |e, list| list.map { |o| { type: e.key, id: o.id } } }))
    end

    GkTags.translated { render layout: 'base' }
  end

  def edit
    @usage = usage_of(@tag)
  end

  # One box of the page in one save: the box Taggen (name, description and marking of a managed tag, the type and the
  # parent, a new parent made without a type), which aliases are suggested, a new handle, a new alias, making a free,
  # established or retired tag managed with its name, description and marking, retire or restore, or merge. The
  # reason with it; each change is its own event on the tag in records.
  # Nothing is kept unless every change is valid: the page comes back with what was written in the box and the message.
  def update
    keys = BOXES[params[:box].to_s]
    return render_error(status: 422) unless keys

    @box = params[:box].to_s
    @form = params[:tag].respond_to?(:permit) ? params[:tag].permit(*keys).to_h : {}
    steps, errors = planned_steps(@form)
    return edit_again(errors) if errors.any?

    reason = nil
    if steps.any? { |s| s.first != :deprecate }
      check = lifecycle_reason(@form[:reason])
      return edit_again([check.error]) unless check.ok

      reason = check.text
    end

    notices = []
    GkTagsTag.transaction do
      steps.each do |step|
        ok, errs, notice = run_step(step, reason)
        notices << notice if notice
        next if ok

        errors = errs.presence || [l(:error_gk_tags_handle)]
        raise ActiveRecord::Rollback
      end
    end
    if errors.any?
      @tag.reload
      return edit_again(errors)
    end

    if @tag.status == 'merged'
      flash[:notice] = notices.last
      return redirect_to(gk_tags_tags_path)
    end
    flash[:notice] = notices.presence&.join(' ') || l(:notice_successful_update)
    redirect_to edit_gk_tags_tag_path(@tag)
  end

  private

  # The changes the form asks for, in the order they are made, as [kind, ...]; unchanged fields are no step. A parent
  # or a tag to merge with that does not resolve is an error before anything is changed.
  def planned_steps(f)
    steps = []
    errors = []
    merged = @tag.status == 'merged'
    managed = @tag.status == 'managed'
    # name, description and marking: changed in the box Taggen of a managed tag, given by the action that makes a free,
    # established or retired one managed
    promote = @box == 'promote' && f[:promote] == '1' && PROMOTABLE.include?(@tag.status)
    errors << l(:error_gk_tags_promote_status) if @box == 'promote' && !promote
    if f.key?(:name) && ((managed && @box == 'tag') || promote)
      name = f[:name].to_s.strip.first(255)
      desc = f[:description].to_s.gsub("\r\n", "\n")
      marking = GkTags.marking(f[:marking]).to_s
      changed = name != @tag.name.to_s || desc != @tag.description.to_s.gsub("\r\n", "\n") || marking.presence != @tag.marking.presence
      steps << [:promote, name, desc, marking] if !managed || changed
    end
    if f.key?(:type_id) && !merged
      type = f[:type_id].present? ? GkTagsType.find_by(id: f[:type_id]) : nil
      steps << [:type, type] if type&.id != @tag.type_id
    end
    parent_steps(f[:parent].to_s.strip.sub(/\A#/, ''), steps, errors) if f.key?(:parent) && !merged
    steps << [:rename, f[:key].to_s.strip] if f.key?(:key) && f[:key].to_s.strip.sub(/\A#/, '') != @tag.key
    steps << [:alias, f[:alias_handle].to_s.strip, f[:alias_language]] if f[:alias_handle].to_s.strip.present?
    if f[:aliases_shown].present?
      off = Array(f[:deprecated_alias_ids]).map(&:to_i)
      @tag.aliases.each { |a| steps << [:deprecate, a, off.include?(a.id)] if a.deprecated != off.include?(a.id) }
    end
    steps << [@tag.status == 'retired' ? :restore : :retire] if f[:retire] == '1' && !merged
    errors << l(:error_gk_tags_merge_none) if @box == 'merge' && f[:into].to_s.strip.empty? && !merged
    if f[:into].to_s.strip.present? && !merged
      target = GkTags.resolve(f[:into])
      if target
        steps << [:merge, target]
      else
        errors << l(:error_gk_tags_no_such, handle: f[:into].to_s.strip.sub(/\A#/, ''))
      end
    end
    [steps, errors]
  end

  # The parent as written: none, a tag (never itself or one of its descendants: the tag refuses a cycle), or
  # a handle that is no tag yet, made a free tag without a type (Utan typ) in the same transaction and then the parent.
  # A new parent written with a namespace is refused, since it would have the namespace's type; parse_ref has already
  # checked the key. Anything else is an error before anything is changed
  def parent_steps(text, steps, errors)
    return if text == @tag.parent&.ref.to_s
    return steps << [:move, nil] if text.empty?

    found = GkTags.resolve_ref(text)
    case found.status
    when :ok then steps << [:move, found.tag] if found.tag.id != @tag.parent_id
    when :new
      if found.type then errors << l(:error_gk_tags_new_parent_namespace, handle: "##{text}")
      else steps << [:create_parent, found.key]
      end
    when :ambiguous then errors << l(:error_gk_tags_ambiguous, handle: text)
    when :no_type then errors << l(:error_gk_tags_no_namespace, handle: "##{text}")
    when :bad then errors << l(:error_gk_tags_bad_handle, handle: "##{text}")
    else errors << l(:error_gk_tags_no_such, handle: text)
    end
  end

  # One change: [ok, errors, notice]
  def run_step(step, reason)
    u = User.current
    kind, a, b, c = step
    case kind
    when :promote
      was = @tag.status
      ok = GkTags::Lifecycle.promote(@tag, u, name: a, description: b, marking: c, reason: reason)
      [ok, @tag.errors.full_messages, ok && was != 'managed' ? l(:notice_gk_tags_promoted) : nil]
    when :type then [GkTags::Lifecycle.set_type(@tag, u, a, reason: reason), @tag.errors.full_messages]
    when :move then [GkTags::Lifecycle.move(@tag, u, a, reason: reason), @tag.errors.full_messages]
    # a new parent: a free tag without a type (Utan typ); no event of its own
    when :create_parent
      parent = GkTagsTag.create(key: a, kind: 'tag', status: 'free', type_id: nil, created_by_id: u.id)
      return [false, parent.errors.full_messages] unless parent.persisted?

      [GkTags::Lifecycle.move(@tag, u, parent, reason: reason), @tag.errors.full_messages]
    when :rename
      ok = GkTags::Lifecycle.rename(@tag, u, a, reason: reason)
      [ok, @tag.errors.full_messages.presence || [l(:error_gk_tags_handle)], ok ? l(:notice_gk_tags_renamed, key: @tag.key) : nil]
    when :alias then GkTags::Lifecycle.add_alias(@tag, u, a, language: b, reason: reason)
    # An alias that may stand in stored text is never removed, only deprecated (### identity)
    when :deprecate then [a.update(deprecated: b), a.errors.full_messages]
    when :retire then [GkTags::Lifecycle.retire(@tag, u, reason: reason) || true, []]
    when :restore then [GkTags::Lifecycle.restore(@tag, u, reason: reason) || true, []]
    when :merge
      ok, errs = GkTags::Lifecycle.merge(@tag, a, u, reason: reason)
      [ok, errs, ok ? l(:notice_gk_tags_merged, into: a.key) : nil]
    end
  end

  # The page again with what was written and the message
  def edit_again(errors)
    @usage = usage_of(@tag)
    flash.now[:error] = errors.uniq.join(', ')
    render :edit, status: :unprocessable_entity
  end

  # How much the tag is used on issues, with the tags merged into it: [issues, projects, last put on]
  def usage_of(tag)
    rel = GkTagsTagging.active.where(tag_id: tag.self_and_merged_ids, taggable_type: 'Issue')
    [rel.distinct.count(:taggable_id), rel.where.not(project_id: nil).distinct.count(:project_id), rel.maximum(:created_at)]
  end

  # The place tags.lifecycle in gk_records decides whether the reason is required (optional by default, as before).
  # Without records the reason is passed on as written. A result with ok, text and error.
  def lifecycle_reason(value)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('tags.lifecycle', value) : nil
    check || Struct.new(:ok, :text, :error).new(true, value.to_s.strip.presence, nil)
  end

  # [[entry, [object]]] for the registered objects other than issues that carry the tags and the viewer may see
  def other_objects(tag_ids)
    GkTags::Taggables.others.filter_map do |e|
      next unless GkTags::Taggables.on?(e) && (klass = e.class_name.safe_constantize)

      ids = GkTagsTagging.active.where(tag_id: tag_ids, taggable_type: e.class_name).pluck(:taggable_id).uniq
      list = klass.where(id: ids).limit(200).to_a.select { |o| e.view.call(o, User.current) }
      [e, list] if list.any?
    end
  end

  # The list is an administrator's; an OAuth token needs the scope gk_tags_api_admin (or :admin), so a token can be
  # narrowed to it. Without compat, core's admin check.
  def require_admin_scope
    return unless require_login

    ok = gk_compat_shim?(:admin_allows?) ? ::GkCompat.call(:admin_allows?, User.current, :gk_tags_api_admin) : User.current.admin?
    render_403 unless ok
  end

  # gk_compat is there and has the shim for the running series (an older gk_compat has no scope check)
  def gk_compat_shim?(name)
    defined?(::GkCompat) && ::GkCompat.respond_to?(:used) && ::GkCompat.used.shims.key?(name)
  end

  def find_tag
    @tag = GkTagsTag.global.find_by(id: params[:id])
    render_404 unless @tag
  end
end
