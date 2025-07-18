# frozen_string_literal: true

class SurveysController < ApplicationController
  helper Rapidfire::ApplicationHelper
  include CourseHelper
  include SurveysHelper
  include QuestionGroupsHelper

  before_action :require_admin_permissions, except: %i[show optout]
  before_action :set_survey, only: %i[
    show
    optout
    edit
    update
    destroy
    edit_question_groups
    course_select
  ]
  before_action :ensure_logged_in
  before_action :set_question_groups, only: %i[
    show
    edit
    edit_question_groups
  ]
  before_action :check_if_closed, only: [:show]
  before_action :set_notification, only: [:show]

  # via SurveysHelper
  before_action :set_course, only: [:show]

  # GET /surveys
  # GET /surveys.json
  def index
    @surveys = Survey.includes(:versions, :survey_assignments,
                               rapidfire_question_groups: :questions).all
  end

  def results_index
    @surveys = Survey.all
  end

  # GET /surveys/1
  # GET /surveys/1.json
  def show
    unless validate_user_for_survey
      redirect_to(main_app.root_path,
                  flash: { notice: 'Sorry, You do not have access to this survey' })
      return
    end
    # The surveys are highly inaccessible via screen reader.
    # Disabling the javascript and css bypasses many of the UI features of
    # the surveys and puts all questions on display at once, but it is gets
    # around the accessibility probems.
    @accessibility_mode = true if params['accessibility'] == 'true'
    filter_inapplicable_question_groups
    render layout: 'surveys_minimal'
  end

  def optout
    render layout: 'application'
  end

  def course_select
    @courses = Course.all
  end

  # GET /surveys/new
  def new
    @survey = Survey.new
  end

  # GET /surveys/1/edit
  def edit; end

  # GET /surveys/1/question_group
  def edit_question_groups; end

  # POST /surveys
  # POST /surveys.json
  def create
    @survey = Survey.new(survey_params)
    raise FailedSaveError unless @survey.save
    respond_to do |format|
      format.html { redirect_to surveys_path, notice: 'Survey was successfully created.' }
      format.json { render :show, status: :created, location: @survey }
    end
  end

  # PATCH/PUT /surveys/1
  # PATCH/PUT /surveys/1.json
  def update
    raise FailedSaveError unless @survey.update(survey_params)
    respond_to do |format|
      format.html { redirect_to surveys_path, notice: 'Survey was successfully updated.' }
      format.json { render :show, status: :ok, location: @survey }
    end
  end

  # DELETE /surveys/1
  # DELETE /surveys/1.json
  def destroy
    @survey.destroy
    respond_to do |format|
      format.html { redirect_to surveys_url, notice: 'Survey was successfully destroyed.' }
      format.json { head :no_content }
    end
  end

  def clone_question_group
    # Fetch the original question group and its questions
    @original_group = Rapidfire::QuestionGroup.includes(:questions).find(params[:id])
    @clone_group = @original_group.deep_clone include: [:questions]
    @clone_group.name = "#{@clone_group.name} (Copy)"
    @clone_group.save

    update_cloned_conditionals
    redirect_to rapidfire.question_groups_path
  end

  def clone_question
    clone = Rapidfire::Question.find(params[:id]).deep_clone
    clone.question_text = "(Copy) #{clone.question_text}"
    clone.save
    redirect_to rapidfire.question_group_questions_url(clone.question_group_id)
  end

  def update_question_group_position
    question_group = SurveysQuestionGroup.find_by!(
      survey_id: params[:survey_id],
      rapidfire_question_group_id: params[:question_group_id]
    )
    question_group.insert_at(params[:position].to_i)
    head :ok
  end

  private

  def set_survey
    @survey = Survey.find(params[:id])
  end

  def set_question_groups
    @question_groups = Rapidfire::QuestionGroup.all
    @surveys_question_groups = SurveysQuestionGroup.by_position(params[:id])
  end

  # This removes the question groups that do not apply to the course, because
  # of the 'tags' parameter that makes the question group apply only to courses
  # with (all) those tags, or to courses in all the specified campaigns.
  def filter_inapplicable_question_groups
    @surveys_question_groups.to_a.select! do |survey_question_group|
      next false if survey_question_group.question_group.questions.empty?
      # via QuestionGroupsHelper
      course_meets_conditions_for_question_group?(survey_question_group.question_group)
    end
  end

  # Never trust parameters from the scary internet.
  def survey_params
    params.require(:survey).permit(:name,
                                   :intro,
                                   :thanks,
                                   :optout,
                                   :closed,
                                   :open,
                                   rapidfire_question_group_ids: [])
  end

  def validate_user_for_survey
    return true if @survey.open
    return true if can_administer?
    return true if user_is_assigned_to_survey
    return false
  end

  def user_is_assigned_to_survey(return_notification = false)
    return false if current_user.nil?
    notifications = current_user.survey_notifications.select do |n|
      n if n.survey.id == @survey.id
    end
    return false if notifications.empty?
    return true unless return_notification
    return notifications.first
  end

  def ensure_logged_in
    return if params.include?('preview') # allow preview even by logged out users
    return true if current_user
    render 'login'
  end

  def check_if_closed
    return if params.include?('preview') # allow preview of a closed survey
    return unless @survey.closed
    redirect_to(main_app.root_path, flash: { notice: 'Sorry, this survey has been closed.' })
  end

  def set_notification
    @notification = user_is_assigned_to_survey(true)
  end

  # Prevents access to survey results if they are set to be confidential
  def protect_confidentiality
    return unless @survey.confidential_results
    render plain: 'The results for this survey are confidential.',
           status: :forbidden
    yield
  end

  def update_cloned_conditionals # rubocop:disable Metrics/AbcSize
    # Cache all questions related to the original group for fast lookup
    original_questions = @original_group.questions.index_by(&:id)

    # Cache all cloned questions for fast lookup
    cloned_questions = @clone_group.questions.index_by(&:position)

    @clone_group.questions.each do |question|
      next unless question.conditionals.present?

      # Extract the original question ID from cloned conditionals question
      original_question_id = question.conditionals.split('|').first.to_i
      original_question = original_questions[original_question_id]

      # Skip if no matching original question and update cloned question conditionals to nil
      next question.update(conditionals: nil) unless original_question.present?

      # Find the cloned equivalent of the original question
      cloned_question = cloned_questions[original_question.position]

      # Update the conditionals with the cloned question's ID
      updated_conditionals = question.conditionals.gsub(/\d+/, cloned_question.id.to_s)
      question.update(conditionals: updated_conditionals)
    end
  end

  class FailedSaveError < StandardError; end
end
