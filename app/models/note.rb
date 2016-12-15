class Note < ActiveRecord::Base
  extend ActiveModel::Naming
  include Gitlab::CurrentSettings
  include Participable
  include Mentionable
  include Awardable
  include Importable
  include FasterCacheKeys
  include CacheMarkdownField

  cache_markdown_field :note, pipeline: :note

  # Attribute containing rendered and redacted Markdown as generated by
  # Banzai::ObjectRenderer.
  attr_accessor :redacted_note_html

  # An Array containing the number of visible references as generated by
  # Banzai::ObjectRenderer
  attr_accessor :user_visible_reference_count

  default_value_for :system, false

  attr_mentionable :note, pipeline: :note
  participant :author

  belongs_to :project
  belongs_to :noteable, polymorphic: true, touch: true
  belongs_to :author, class_name: "User"
  belongs_to :updated_by, class_name: "User"

  # Only used by DiffNote, but defined here so that it can be used in `Note.includes`
  belongs_to :resolved_by, class_name: "User"

  has_many :todos, dependent: :destroy
  has_many :events, as: :target, dependent: :destroy

  delegate :gfm_reference, :local_reference, to: :noteable
  delegate :name, to: :project, prefix: true
  delegate :name, :email, to: :author, prefix: true
  delegate :title, to: :noteable, allow_nil: true

  validates :note, :project, presence: true

  # Attachments are deprecated and are handled by Markdown uploader
  validates :attachment, file_size: { maximum: :max_attachment_size }

  validates :noteable_type, presence: true
  validates :noteable_id, presence: true, unless: [:for_commit?, :importing?]
  validates :commit_id, presence: true, if: :for_commit?
  validates :author, presence: true

  validate unless: [:for_commit?, :importing?] do |note|
    unless note.noteable.try(:project) == note.project
      errors.add(:invalid_project, 'Note and noteable project mismatch')
    end
  end

  mount_uploader :attachment, AttachmentUploader

  # Scopes
  scope :for_commit_id, ->(commit_id) { where(noteable_type: "Commit", commit_id: commit_id) }
  scope :system, ->{ where(system: true) }
  scope :user, ->{ where(system: false) }
  scope :common, ->{ where(noteable_type: ["", nil]) }
  scope :fresh, ->{ order(created_at: :asc, id: :asc) }
  scope :inc_author_project, ->{ includes(:project, :author) }
  scope :inc_author, ->{ includes(:author) }
  scope :inc_relations_for_view, ->{ includes(:project, :author, :updated_by, :resolved_by, :award_emoji) }

  scope :diff_notes, ->{ where(type: ['LegacyDiffNote', 'DiffNote']) }
  scope :non_diff_notes, ->{ where(type: ['Note', nil]) }

  scope :with_associations, -> do
    # FYI noteable cannot be loaded for LegacyDiffNote for commits
    includes(:author, :noteable, :updated_by,
             project: [:project_members, { group: [:group_members] }])
  end

  after_initialize :ensure_discussion_id
  before_validation :nullify_blank_type, :nullify_blank_line_code
  before_validation :set_discussion_id
  after_save :keep_around_commit

  class << self
    def model_name
      ActiveModel::Name.new(self, nil, 'note')
    end

    def build_discussion_id(noteable_type, noteable_id)
      [:discussion, noteable_type.try(:underscore), noteable_id].join("-")
    end

    def discussion_id(*args)
      Digest::SHA1.hexdigest(build_discussion_id(*args))
    end

    def discussions
      Discussion.for_notes(all)
    end

    def grouped_diff_discussions
      active_notes = diff_notes.fresh.select(&:active?)
      Discussion.for_diff_notes(active_notes).
        map { |d| [d.line_code, d] }.to_h
    end
  end

  def cross_reference?
    system && SystemNoteService.cross_reference?(note)
  end

  def diff_note?
    false
  end

  def legacy_diff_note?
    false
  end

  def new_diff_note?
    false
  end

  def active?
    true
  end

  def resolvable?
    false
  end

  def resolved?
    false
  end

  def to_be_resolved?
    resolvable? && !resolved?
  end

  def max_attachment_size
    current_application_settings.max_attachment_size.megabytes.to_i
  end

  def hook_attrs
    attributes
  end

  def for_commit?
    noteable_type == "Commit"
  end

  def for_issue?
    noteable_type == "Issue"
  end

  def for_merge_request?
    noteable_type == "MergeRequest"
  end

  def for_snippet?
    noteable_type == "Snippet"
  end

  # override to return commits, which are not active record
  def noteable
    if for_commit?
      project.commit(commit_id)
    else
      super
    end
  # Temp fix to prevent app crash
  # if note commit id doesn't exist
  rescue
    nil
  end

  # FIXME: Hack for polymorphic associations with STI
  #        For more information visit http://api.rubyonrails.org/classes/ActiveRecord/Associations/ClassMethods.html#label-Polymorphic+Associations
  def noteable_type=(noteable_type)
    super(noteable_type.to_s.classify.constantize.base_class.to_s)
  end

  # Reset notes events cache
  #
  # Since we do cache @event we need to reset cache in special cases:
  # * when a note is updated
  # * when a note is removed
  # Events cache stored like  events/23-20130109142513.
  # The cache key includes updated_at timestamp.
  # Thus it will automatically generate a new fragment
  # when the event is updated because the key changes.
  def reset_events_cache
    Event.reset_event_cache_for(self)
  end

  def editable?
    !system?
  end

  def cross_reference_not_visible_for?(user)
    cross_reference? && !has_referenced_mentionables?(user)
  end

  def has_referenced_mentionables?(user)
    if user_visible_reference_count.present?
      user_visible_reference_count > 0
    else
      referenced_mentionables(user).any?
    end
  end

  def award_emoji?
    can_be_award_emoji? && contains_emoji_only?
  end

  def emoji_awardable?
    !system?
  end

  def can_be_award_emoji?
    noteable.is_a?(Awardable)
  end

  def contains_emoji_only?
    note =~ /\A#{Banzai::Filter::EmojiFilter.emoji_pattern}\s?\Z/
  end

  def award_emoji_name
    note.match(Banzai::Filter::EmojiFilter.emoji_pattern)[1]
  end

  private

  def keep_around_commit
    project.repository.keep_around(self.commit_id)
  end

  def nullify_blank_type
    self.type = nil if self.type.blank?
  end

  def nullify_blank_line_code
    self.line_code = nil if self.line_code.blank?
  end

  def ensure_discussion_id
    return unless self.persisted?
    # Needed in case the SELECT statement doesn't ask for `discussion_id`
    return unless self.has_attribute?(:discussion_id)
    return if self.discussion_id

    set_discussion_id
    update_column(:discussion_id, self.discussion_id)
  end

  def set_discussion_id
    self.discussion_id = Digest::SHA1.hexdigest(build_discussion_id)
  end

  def build_discussion_id
    if for_merge_request?
      # Notes on merge requests are always in a discussion of their own,
      # so we generate a unique discussion ID.
      [:discussion, :note, SecureRandom.hex].join("-")
    else
      self.class.build_discussion_id(noteable_type, noteable_id || commit_id)
    end
  end
end
