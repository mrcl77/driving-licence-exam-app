# frozen_string_literal: true

class ApplicationController < ActionController::Base
  before_action :set_interface_locale

  UI_LOCALES = %w[pl en].freeze

  private

  def set_interface_locale
    requested = params[:ui_lang].to_s
    selected = if UI_LOCALES.include?(requested)
                 requested
               elsif UI_LOCALES.include?(session[:ui_lang].to_s)
                 session[:ui_lang].to_s
               else
                 I18n.default_locale.to_s
               end

    I18n.locale = selected
    session[:ui_lang] = selected
  end
end
