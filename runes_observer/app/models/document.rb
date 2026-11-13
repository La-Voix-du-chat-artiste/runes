# frozen_string_literal: true

# An uploaded document, addressed by content: `sha` is the SHA-256 of the
# bytes and `ext` the extension, so the pair is the address the harness's
# Runes::DocStore uses on disk (`<root>/ab/cd/<sha>.<ext>`).
class Document < ApplicationRecord
  SHA_RE = /\A[0-9a-f]{64}\z/
  # Mirror of Runes::DocStore::EXTS — the classifier mirrors the topic map the
  # same way; the harness stays the source of truth, this copy keeps the model
  # loadable even when the harness is not on the load path.
  EXTS = %w[txt md pdf json csv html].freeze

  validates :sha, presence: true, format: { with: SHA_RE }
  validates :ext, presence: true, inclusion: { in: EXTS }
  validates :bytes, numericality: { only_integer: true, greater_than: 0 }
  validates :name, presence: true
  validates :sha, uniqueness: { scope: :ext }

  scope :recent, -> { order(created_at: :desc, id: :desc) }

  def short_sha
    sha[0, 12]
  end
end
