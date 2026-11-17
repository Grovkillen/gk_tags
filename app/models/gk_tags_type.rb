# frozen_string_literal: true

# A tag type (plugins/tags ### types): key, a name and a description as written (other languages are fields'
# translations, as for every other name an administrator sets), a category of the shared palette (1 to 12), an icon, and
# its rules: exclusive (at most one tag of the type per object), allowed_on (the taggable keys a tag of the type may
# be put on; empty means everywhere), required_for (taggable keys that must carry a tag of the type when their tags
# are written), namespace (the qualifier in #ns:value), inherit_parents (a search on a parent finds the children) and
# repeat_keys (the same key under different parents, written with its path). Never deleted; retired is active false.
class GkTagsType < ApplicationRecord
  self.table_name = 'gk_tags_types'

  # The study's own types (ort, bransch, förmåga, etablering, infrastruktur) are not here: they are made by an
  # administrator or a scenario.
  # requirement needs processes and is not seeded.
  SEED = [
    { key: 'product', category: 1,
      names: { 'sv' => 'Produkt', 'en' => 'Product' },
      descriptions: { 'sv' => 'Produkter och artiklar som arbetet gäller.', 'en' => 'Products and articles the work concerns.' } },
    { key: 'technology', category: 6,
      names: { 'sv' => 'Teknik', 'en' => 'Technology' },
      descriptions: { 'sv' => 'Tekniker, gränssnitt och standarder, gärna i en hierarki (Teknik/CAN/CANopen).',
                      'en' => 'Technologies, interfaces and standards, preferably in a hierarchy (Technology/CAN/CANopen).' } },
    { key: 'classification', category: 3,
      names: { 'sv' => 'Klassning', 'en' => 'Classification' },
      descriptions: { 'sv' => 'Klassningar som säkerhetskritiskt eller prioritetsklass.', 'en' => 'Classifications such as safety critical or priority class.' } },
    { key: 'process', category: 2,
      names: { 'sv' => 'Process', 'en' => 'Process' },
      descriptions: { 'sv' => 'Processer och områden i verksamheten som arbetet hör till.', 'en' => 'Processes and areas of the organization the work belongs to.' } },
    { key: 'marker', category: 10,
      names: { 'sv' => 'Markör', 'en' => 'Marker' },
      descriptions: { 'sv' => 'Processmarkörer som behöver granskning.', 'en' => 'Process markers such as needs review.' } },
    { key: 'event', category: 5,
      names: { 'sv' => 'Evenemang', 'en' => 'Event' },
      descriptions: { 'sv' => 'Tillfälliga strukturer som en mässa eller en kampanj.', 'en' => 'Temporary structures such as a trade fair or a campaign.' } },
    { key: 'free', category: nil,
      names: { 'sv' => 'Fri', 'en' => 'Free' },
      descriptions: { 'sv' => 'Fria taggar utan annan typ. En tagg utan typ följer den här typens regler.',
                      'en' => 'Free tags without another type. A tag without a type follows the rules of this type.' } }
  ].freeze
  FREE = 'free'
  KEY = /\A[a-z][a-z0-9_]*\z/

  has_many :tags, class_name: 'GkTagsTag', foreign_key: :type_id

  validates :key, presence: true, length: { maximum: 40 }, uniqueness: true, format: { with: KEY }
  validates :namespace, length: { maximum: 40 }, allow_blank: true
  validates :category, inclusion: { in: GkTags::CATEGORIES }, allow_nil: true
  validates :icon, length: { maximum: 80 }, allow_blank: true
  validate :namespace_free
  validate :key_kept, on: :update

  before_validation { self.namespace = namespace.present? ? (GkTags.normalize(namespace) || namespace.to_s.strip) : nil }

  scope :sorted, -> { order(:position, :key) }
  scope :active, -> { where(active: true) }

  # The seeded types are named and described in English whatever the installation's language is; the seed's other
  # languages go to fields' translations when fields is there (GkFields::Translations.seed_record!)
  def self.ensure_seeded!
    return if exists?

    transaction do
      SEED.each_with_index do |s, i|
        type = create!(key: s[:key], category: s[:category], position: i + 1, name: s[:names]['en'], description: s[:descriptions]['en'])
        type.keep_other_languages!(s[:names], s[:descriptions])
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[gk_tags] seeding the types failed: #{e.class}: #{e.message}")
    nil
  end

  def self.json_list(text)
    v = text.present? ? JSON.parse(text) : []
    v.is_a?(Array) ? v.map(&:to_s).reject(&:empty?).uniq : []
  rescue JSON::ParserError
    []
  end

  def self.json_hash(text)
    v = text.present? ? JSON.parse(text) : {}
    v.is_a?(Hash) ? v.transform_keys(&:to_s).transform_values(&:to_s).reject { |_, x| x.strip.empty? } : {}
  rescue JSON::ParserError
    {}
  end

  def allowed_on_list = self.class.json_list(allowed_on)
  def required_for_list = self.class.json_list(required_for)

  def allowed_on_list=(list)
    self.allowed_on = Array(list).map(&:to_s).reject(&:empty?).uniq.to_json
  end

  def required_for_list=(list)
    self.required_for = Array(list).map(&:to_s).reject(&:empty?).uniq.to_json
  end

  # { lang => text } without empty texts
  def self.texts(h) = (h || {}).to_h.to_h { |k, v| [k.to_s, v.to_s.strip] }.reject { |_, v| v.empty? }

  # The language a name is written in: the installation's default language
  def self.written_lang = ::Setting.default_language.to_s.presence || 'sv'

  # { name:, description: } in the written language out of texts per language (that language, then Swedish, English,
  # any)
  def self.written(names, descriptions)
    n = texts(names)
    d = texts(descriptions)
    { name: pick(n), description: pick(d) }
  end

  def self.pick(h)
    return nil if h.empty?

    [written_lang, 'sv', 'en'].each { |l| return h[l] if h[l].present? }
    h.values.first
  end

  # A seeded type's name and description in every language of the seed, into fields' translations (English included,
  # so that the English text reads right in any installation language); a text already changed is left alone
  def keep_other_languages!(names, descriptions)
    return unless defined?(::GkFields::Translations) && ::GkFields::Translations.respond_to?(:seed_record!)

    { 'name' => names, 'description' => descriptions }.each do |attr, h|
      ::GkFields::Translations.seed_record!('GkTagsType', self, attr, self.class.texts(h))
    end
  end

  # The name and the description per language, as the API gives them: the written one and fields' translations
  def names_hash = texts_in(:name)
  def descriptions_hash = texts_in(:description)

  def texts_in(attr)
    if defined?(::GkFields::Translations) && ::GkFields::Translations.respond_to?(:texts_for)
      return ::GkFields::Translations.texts_for('GkTagsType', id, attr, self[attr], lang: self.class.written_lang)
    end

    stored = defined?(::GkFieldsTranslation) ? ::GkFieldsTranslation.find_by(record_type: 'GkTagsType', record_id: id, attribute_name: attr.to_s, value_key: nil) : nil
    (stored ? stored.translations_hash : {}).merge(self.class.written_lang => self[attr].to_s).reject { |_l, v| v.to_s.strip.empty? }
  end

  # The name as shown: fields translates it where a page is drawn; the key when it has none
  def to_s = name.presence || key

  def free? = key == FREE
  def allowed_on?(taggable_key) = allowed_on_list.empty? || allowed_on_list.include?(taggable_key.to_s)
  def required_for?(taggable_key) = active && required_for_list.include?(taggable_key.to_s)
  def namespaced? = namespace.present?

  private

  # A qualifier is unique among the types and is a valid handle
  def namespace_free
    return if namespace.blank?
    return errors.add(:namespace, :invalid) unless GkTags.normalize(namespace) == namespace

    errors.add(:namespace, :taken) if self.class.where(namespace: namespace).where.not(id: id).exists?
  end

  # The key is what scenarios, REST and other plugins name the type by: it never changes once made
  def key_kept
    errors.add(:key, :invalid) if key_changed?
  end
end
