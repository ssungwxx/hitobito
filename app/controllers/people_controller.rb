# encoding: utf-8

#  Copyright (c) 2012-2013, Jungwacht Blauring Schweiz. This file is part of
#  hitobito and licensed under the Affero General Public License version 3
#  or later. See the COPYING file at the top-level directory or at
#  https://github.com/hitobito/hitobito.

class PeopleController < CrudController

  include Concerns::RenderPeopleExports

  self.nesting = Group

  self.remember_params += [:name, :kind, :role_type_ids]

  self.permitted_attrs = [:first_name, :last_name, :company_name, :nickname, :company,
                          :gender, :birthday, :additional_information,
                          :picture, :remove_picture] +
                          Contactable::ACCESSIBLE_ATTRS +
                          [relations_to_tails_attributes: [:id, :tail_id, :kind, :_destroy]]


  # required to allow api calls
  protect_from_forgery with: :null_session, only: [:index, :show]


  decorates :group, :person, :people, :add_requests

  helper_method :index_full_ability?

  # load group before authorization
  prepend_before_action :parent

  prepend_before_action :entry, only: [:show, :edit, :update, :destroy,
                                       :send_password_instructions, :primary_group]

  before_render_show :load_person_add_requests, if: -> { html_request? }
  before_render_index :load_people_add_requests, if: -> { html_request? }

  def index
    respond_to do |format|
      format.html  { @people = prepare_entries(filter_entries).page(params[:page]) }
      format.pdf   { render_pdf(condense_entries) }
      format.csv   { render_entries_csv(filter_entries) }
      format.email { render_emails(filter_entries) }
      format.json  { render_entries_json(filter_entries) }
    end
  end

  def show
    respond_to do |format|
      format.html
      format.pdf  { render_pdf([entry]) }
      format.csv  { render_entry_csv }
      format.json { render_entry_json }
    end
  end

  # POST button, send password instructions
  def send_password_instructions
    Person::SendLoginJob.new(entry, current_user).enqueue!
    notice = I18n.t("#{controller_name}.#{action_name}")
    respond_to do |format|
      format.html { redirect_to group_person_path(group, entry), notice: notice }
      format.js do
        flash.now.notice = notice
        render 'shared/update_flash'
      end
    end
  end

  # PUT button, ajax
  def primary_group
    entry.update_column :primary_group_id, params[:primary_group_id]
    respond_to do |format|
      format.html { redirect_to group_person_path(group, entry) }
      format.js
    end
  end

  private

  # dont use class level accessor as expression is evaluated whenever constant is
  # loaded which might be before wagon that defines groups / roles has been loaded
  def self.sort_mappings_with_indifferent_access
    { roles: [Person.order_by_role_statement].
      concat(Person.order_by_name_statement) }.with_indifferent_access
  end


  alias_method :group, :parent

  def find_entry
    if group && group.root?
      # every person may be displayed underneath the root group,
      # even if it does not directly belong to it.
      Person.find(params[:id])
    else
      super
    end
  end

  def assign_attributes
    if model_params.present?
      email = model_params.delete(:email)
      entry.email = email if can?(:update_email, entry)
    end
    super
  end

  def load_people_add_requests
    if params[:kind].blank? && can?(:create, @group.roles.new)
      @person_add_requests = @group.person_add_requests.list.includes(person: :primary_group)
    end
  end

  def load_person_add_requests
    if can?(:update, entry)
      @add_requests = entry.add_requests.includes(:body, requester: { roles: :group })
      set_add_request_status_notification if show_add_request_status?
    end
  end

  def show_add_request_status?
    flash[:notice].blank? && flash[:alert].blank? &&
    params[:body_type].present? && params[:body_id].present?
  end

  def set_add_request_status_notification
    status = Person::AddRequest::Status.for(entry.id, params[:body_type], params[:body_id])
    return if status.pending?

    if status.created?
      flash.now[:notice] = status.approved_message
    else
      flash.now[:alert] = status.rejected_message
    end
  end

  def filter_entries
    filter = list_filter
    entries = filter.filter_entries
    entries = entries.reorder(sort_expression) if sorting?
    @multiple_groups = filter.multiple_groups
    @all_count = filter.all_count if html_request?
    entries
  end

  def condense_entries
    return filter_entries unless params[:condense_labels] == 'true'
    Person::CondensedContact.condense_list(filter_entries)
  end

  def list_filter
    if params[:filter] == 'qualification' && index_full_ability?
      Person::QualificationFilter.new(@group, current_user, params)
    else
      Person::RoleFilter.new(@group, current_user, params)
    end
  end

  def prepare_entries(entries)
    if index_full_ability?
      entries.includes(:additional_emails, :phone_numbers)
    else
      entries.preload_public_accounts
    end
  end

  def render_entries_csv(entries)
    full = params[:details].present? && index_full_ability?
    render_csv(prepare_csv_entries(entries, full), full)
  end

  def prepare_csv_entries(entries, full)
    if full
      entries.select('people.*').preload_accounts.includes(relations_to_tails: :tail)
    else
      entries.preload_public_accounts
    end
  end

  def render_entry_csv
    render_csv([entry], params[:details].present? && can?(:show_full, entry))
  end

  def render_csv(entries, full)
    if full
      send_data Export::Csv::People::PeopleFull.export(entries), type: :csv
    else
      send_data Export::Csv::People::PeopleAddress.export(entries), type: :csv
    end
  end

  def render_entries_json(entries)
    render json: ListSerializer.new(prepare_entries(entries).
                                      includes(:social_accounts).
                                      decorate,
                                    group: @group,
                                    multiple_groups: @multiple_groups,
                                    serializer: PeopleSerializer,
                                    controller: self)
  end

  def render_entry_json
    render json: PersonSerializer.new(entry.decorate, group: @group, controller: self)
  end

  def index_full_ability?
    if params[:kind].blank?
      can?(:index_full_people, @group)
    else
      can?(:index_deep_full_people, @group)
    end
  end
  public :index_full_ability? # for serializer
  hide_action :index_full_ability?

  def authorize_class
    authorize!(:index_people, group)
  end

end
