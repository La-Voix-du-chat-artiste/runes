class BoardController < ApplicationController
  # The fleet board: Planned / Working / Done, folded from the packets the
  # observer already stores (app/services/board/kanban.rb).
  def show
    @board = build_board
    @columns = @board.columns
    @diagram = @board.to_mmd
    @agents = @board.agents
    @window = @board.window
    @truncated = @board.truncated
  end

  # The artifact itself: what an agent, `bin/runes-replay` or you over ssh can
  # read instead of opening a browser. Same bytes the page renders.
  def mmd
    send_data build_board.to_mmd,
              type: "text/plain; charset=utf-8",
              disposition: "inline",
              filename: "board.mmd"
  end

  private

  def build_board
    Board::Kanban.new(window: window, agent_id: params[:agent_id], limit: limit)
  end

  def window
    hours = params[:hours].to_i
    hours.positive? ? hours.hours : Board::Kanban::DEFAULT_WINDOW
  end

  def limit
    requested = params[:limit].to_i
    requested.positive? ? [requested, 200].min : Board::Kanban::DEFAULT_LIMIT
  end
end
