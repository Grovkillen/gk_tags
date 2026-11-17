# frozen_string_literal: true

# Administration > Taggar > Typer: the types with their names and descriptions per language, colour, icon and rules,
# made and changed by an administrator. A type is never deleted; it is retired and restored. Every change is an event
# on the type in records, with the reason of the place tags.lifecycle. REST: the list and one type for whoever may
# see tags (the types say what tags mean; they hold nothing about anyone).
class GkTagsTypesController < ApplicationController
  include GkTags::Gate::Controller
  layout 'admin'
  self.main_menu = false
  accept_api_auth :index, :show
  before_action :authorize_read, only: %i[index show]
  before_action :require_admin, except: %i[index show]
  before_action :find_type, except: %i[index new create]
  helper :gk_tags

  def index
    @types = GkTags::Types.all
    @counts = GkTagsTag.global.usable.where(type_id: @types.map(&:id)).group(:type_id).count
    free = @types.detect(&:free?)
    @counts[free.id] = @counts[free.id].to_i + GkTagsTag.global.usable.where(type_id: nil).count if free
    return render(json: { types: @types.map { |t| GkTags::Json.type(t, @counts[t.id].to_i) } }) if api_request?

    GkTags.translated { render }
  end

  def show
    return redirect_to(edit_gk_tags_type_path(@type)) unless api_request?

    count = GkTagsTag.global.usable.where(type_id: @type.free? ? [nil, @type.id] : @type.id).count
    render json: { type: GkTags::Json.type(@type, count) }
  end

  def new
    @type = GkTagsType.new
  end

  def create
    GkTagsType.ensure_seeded! # the general types are there before the first type of the installation's own
    @type = GkTagsType.new
    return unless (reason = type_reason(params.dig(:type, :reason), :new))

    if GkTags::TypeLifecycle.save(@type, User.current, type_attrs.merge(key: params.dig(:type, :key).to_s.strip.downcase), reason: reason.text)
      flash[:notice] = l(:notice_successful_create)
      redirect_to gk_tags_types_path
    else
      render :new
    end
  end

  def edit; end

  def update
    return unless (reason = type_reason(params.dig(:type, :reason), :edit))

    if GkTags::TypeLifecycle.save(@type, User.current, type_attrs, reason: reason.text)
      flash[:notice] = l(:notice_successful_update)
      redirect_to edit_gk_tags_type_path(@type)
    else
      render :edit
    end
  end

  # Retire, or restore a retired type
  def retire
    if @type.active
      return unless (reason = type_reason(params[:reason], :edit))

      GkTags::TypeLifecycle.retire(@type, User.current, reason: reason.text)
    else
      GkTags::TypeLifecycle.restore(@type, User.current)
    end
    redirect_to edit_gk_tags_type_path(@type)
  end

  private

  # The page for an administrator; REST for whoever may see tags in some project
  def authorize_read
    return require_admin unless api_request?

    deny_access unless User.current.admin? || User.current.allowed_to?(:gk_tags_view, nil, global: true)
  end

  def find_type
    @type = GkTags::Types.find(params[:id])
    render_404 unless @type
  end

  def type_attrs
    p = params.require(:type)
    flag = ->(k) { %w[1 true].include?(p[k].to_s) }
    {
      name: p[:name].to_s.strip.first(255),
      description: p[:description].to_s.strip.presence,
      category: GkTags.category(p[:category]),
      icon: p[:icon].to_s.strip.first(80).presence,
      exclusive: flag.call(:exclusive), inherit_parents: flag.call(:inherit_parents), repeat_keys: flag.call(:repeat_keys),
      allowed_on_list: Array(p[:allowed_on]).map(&:to_s).reject(&:empty?),
      required_for_list: Array(p[:required_for]).map(&:to_s).reject(&:empty?),
      namespace: p[:namespace].to_s.strip.sub(/:\z/, '').presence,
      position: p[:position].to_i
    }
  end

  # The place tags.lifecycle in gk_records decides whether the reason is required (optional by default); a refused
  # reason goes back to the form with the message. Without records the reason is passed on.
  def type_reason(value, back)
    check = defined?(GkRecords::Reasons) ? GkRecords::Reasons.check('tags.lifecycle', value) : nil
    return Struct.new(:text).new(value) unless check
    return check if check.ok

    flash.now[:error] = check.error
    @type.assign_attributes(type_attrs) if params[:type]
    render back
    nil
  end
end
