import {BoardWithImages, API_URL, Board } from "../types";


export async function getBoardWithImages(id: string): Promise<BoardWithImages> {
    const requestInfo = {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
      },
    };
    const response = await fetch(`${API_URL}boards/${id}`, requestInfo);
    const board: BoardWithImages = await response.json();
    console.log("API", board);
    return board;
  }


export async function getBoards(): Promise<Board[]> {
    const requestInfo = {
      method: "GET",
      headers: {
        "Content-Type": "application/json",
        'Accept': 'application/json'
      },
    };
    try {
      // console.log("API_URL", API_URL);
      const response = await fetch(`${API_URL}boards.json`, requestInfo);
      console.log("Response", JSON.stringify(response));
      const boards: Board[] = await response.json();
      // const boards = JSON
      // console.log("API", typeof response);
      return boards;
    }
    catch (e) {
      console.log(e.message);
      console.log(e.stack)
      throw e;
    }
  }