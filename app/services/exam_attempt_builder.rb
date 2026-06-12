# frozen_string_literal: true

class ExamAttemptBuilder
  class BuildError < StandardError; end

  def initialize(license_category:, locale: 'pl', exam_blueprint: nil, question_bank: nil)
    @license_category = license_category
    @locale = locale.to_s
    @exam_blueprint = exam_blueprint || ExamBlueprint.active.order(updated_at: :desc).first
    @question_bank = question_bank || QuestionBank.active.order(imported_at: :desc, updated_at: :desc).first
    @random_seed = SecureRandom.random_number(2**31)
    @random = Random.new(@random_seed)
  end

  def call
    validate!

    assignments = collect_question_assignments
    max_score = assignments.sum { |assignment| assignment.fetch(:points) }

    attempt = ExamAttempt.create!(
      exam_blueprint: @exam_blueprint,
      question_bank: @question_bank,
      license_category: @license_category,
      locale: @locale,
      status: :in_progress,
      started_at: Time.current,
      deadline_at: Time.current + @exam_blueprint.duration_minutes.minutes,
      max_score: max_score,
      random_seed: @random_seed
    )

    assignments.each_with_index do |assignment, index|
      question = assignment.fetch(:question)
      points = assignment.fetch(:points)

      attempt.exam_attempt_items.create!(
        question: question,
        position: index + 1,
        points_possible: points,
        correct_key: question.correct_key
      )
    end

    attempt
  end

  private

  def validate!
    raise BuildError, I18n.t('ui.errors.no_question_bank') if @question_bank.nil?
    raise BuildError, I18n.t('ui.errors.no_exam_blueprint') if @exam_blueprint.nil?
    raise BuildError, I18n.t('ui.errors.invalid_exam_language') unless DrivingTestConstants::LOCALES.include?(@locale)
    raise BuildError, I18n.t('ui.errors.select_license_category') if @license_category.nil?
  end

  def collect_question_assignments
    assignments = []

    %i[basic specialist].each do |scope|
      required_count = scope_count(scope)
      next if required_count <= 0

      scope_assignments = weighted_scope_assignments(scope, required_count)
      scope_assignments ||= fallback_scope_assignments(scope, required_count)
      # Keep scope order (basic first, specialist last), randomize only inside each scope.
      assignments.concat(scope_assignments.shuffle(random: @random))
    end

    assignments
  end

  def scope_count(scope)
    if scope == :basic
      @exam_blueprint.basic_questions_count
    else
      @exam_blueprint.specialist_questions_count
    end
  end

  def weighted_scope_assignments(scope, required_count)
    rules = rules_for_scope(scope)
    return nil if rules.empty?
    return nil unless rules.sum(&:questions_count) == required_count

    selected = []

    rules.each do |rule|
      candidates = scoped_questions(scope)
                   .where(question_weight: rule.question_weight)
                   .where.not(id: selected.map(&:id))
      return nil if candidates.count < rule.questions_count

      selected.concat(sample_relation(candidates, rule.questions_count))
    end

    selected.map { |question| { question: question, points: question.question_weight } }
  end

  def fallback_scope_assignments(scope, required_count)
    candidates = scoped_questions(scope)
    available = candidates.count

    if available < required_count
      scope_label = scope == :basic ? I18n.t('ui.common.scope_basic') : I18n.t('ui.common.scope_specialist')
      raise BuildError, I18n.t(
        'ui.errors.insufficient_questions',
        locale_code: @locale.upcase,
        scope_label: scope_label,
        available: available,
        required: required_count
      )
    end

    selected = sample_relation(candidates, required_count)

    fallback_points = build_fallback_points(scope, required_count)
    selected.each_with_index.map do |question, index|
      { question: question, points: question.question_weight || fallback_points[index] || 1 }
    end
  end

  def build_fallback_points(scope, required_count)
    rules = rules_for_scope(scope)
    if rules.sum(&:questions_count) == required_count
      return rules.flat_map { |rule| [rule.question_weight] * rule.questions_count }.shuffle(random: @random)
    end

    default = default_points_distribution(scope)
    default.first(required_count).shuffle(random: @random)
  end

  def default_points_distribution(scope)
    if scope == :basic
      ([3] * 10) + ([2] * 6) + ([1] * 4)
    else
      ([3] * 6) + ([2] * 4) + ([1] * 2)
    end
  end

  def rules_for_scope(scope)
    @rules_for_scope ||= {}
    @rules_for_scope[scope] ||= @exam_blueprint.exam_blueprint_rules
                                               .where(scope: ExamBlueprintRule.scopes.fetch(scope.to_s))
                                               .order(question_weight: :desc)
                                               .to_a
  end

  def scoped_questions(scope)
    @scoped_questions ||= {}
    @scoped_questions[scope] ||= begin
      base_scope = Question
                   .joins(:question_categories)
                   .where(question_bank: @question_bank, active: true, scope: Question.scopes.fetch(scope.to_s))
                   .where(question_categories: { license_category_id: @license_category.id })

      localized_scope(without_broken_main_media(base_scope))
    end
  end

  def without_broken_main_media(relation)
    broken_main_media_question_ids = QuestionMediaLink
                                     .left_joins(:media_asset)
                                     .where(slot: QuestionMediaLink.slots.fetch('main'))
                                     .where(
                                       'question_media_links.status = :missing_status ' \
                                       'OR question_media_links.media_asset_id IS NULL ' \
                                       'OR media_assets.processing_status = :media_missing_status',
                                       missing_status: QuestionMediaLink.statuses.fetch('missing'),
                                       media_missing_status: MediaAsset.processing_statuses.fetch('missing')
                                     )
                                     .select(:question_id)

    relation.where.not(id: broken_main_media_question_ids)
  end

  def localized_scope(relation)
    return relation if @locale == 'pl'

    # For non-PL attempts, pick only questions translated to selected locale.
    stem_translated = relation.joins(:question_translations).where(question_translations: { locale: @locale })

    # Single-choice questions additionally need all A/B/C options translated.
    single_choice_with_full_options = QuestionOption
                                      .joins(:question_option_translations)
                                      .where(question_option_translations: { locale: @locale })
                                      .group(:question_id)
                                      .having('COUNT(DISTINCT question_options.key) = 3')
                                      .select(:question_id)

    stem_translated.where(
      'questions.answer_mode = :yes_no OR questions.id IN (:translated_single_choice_ids)',
      yes_no: Question.answer_modes.fetch('yes_no'),
      translated_single_choice_ids: single_choice_with_full_options
    )
  end

  def sample_relation(relation, count)
    relation.order(Arel.sql('RANDOM()')).limit(count).to_a
  end
end
