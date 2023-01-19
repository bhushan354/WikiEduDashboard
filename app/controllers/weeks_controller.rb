# frozen_string_literal: true
require "#{Rails.root}/lib/alerts/deleted_timeline_alert_manager"
class WeeksController < ApplicationController
  respond_to :json

  def destroy
    course = Week.find(params[:id]).course
    Week.find(params[:id]).destroy
    DeletedTimelineAlertManager.new(course)
    render plain: '', status: :ok
  end
end
