# Workspace slice 2B (docs/WORKSPACE_PLAN.md): named MQTT broker profiles.
# Test probes a connector (short connection reading retained Agent Cards);
# Activate makes it the broker the ingest subscribes through by bumping
# ingest_statuses.connector_epoch, which FabricIngest polls and rebuilds on.
# With no active connector the ingest uses the RUNES_MQTT_* env vars as before.
class ConnectorsController < ApplicationController
  def index
    @connectors = Connector.order(:active, :name).to_a
    @active = Connector.active.order(:id).first
    @env_target = "#{IngestStatus.default_host}:#{IngestStatus.default_port}"
  end

  def new
    @connector = Connector.new(port: 1883, transport: "auto")
  end

  def create
    @connector = Connector.new(connector_params)
    if @connector.save
      redirect_to connectors_path, notice: "Connector #{@connector.name} added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @connector = Connector.find(params[:id])
  end

  def update
    @connector = Connector.find(params[:id])
    if @connector.update(connector_params)
      redirect_to connectors_path, notice: "Connector #{@connector.name} updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @connector = Connector.find(params[:id])
    was_active = @connector.active?
    @connector.destroy!
    # If the active connector is deleted, the ingest falls back to env on the
    # next rebuild; bump the epoch so it does not keep watching a dead profile.
    ConnectorManager.activate!(Connector.first!) if was_active && Connector.any?
    redirect_to connectors_path, notice: "Connector #{@connector.name} deleted."
  end

  def test
    @connector = Connector.find(params[:id])
    result = ConnectorManager.probe(@connector)
    if result[:state] == "ok"
      redirect_to connectors_path, notice: "#{@connector.name}: #{result[:detail]}"
    else
      redirect_to connectors_path, alert: "#{@connector.name}: probe failed — #{result[:detail]}"
    end
  end

  def activate
    @connector = Connector.find(params[:id])
    ConnectorManager.activate!(@connector)
    redirect_to connectors_path,
                notice: "#{@connector.name} is now the active connector — the ingest rebuilds onto #{@connector.host}:#{@connector.port}."
  end

  private

  def connector_params
    params.require(:connector).permit(:name, :host, :port, :transport, :tls,
                                      :client_id, :username, :password_env, :active)
  end
end
