import React, { useEffect, useState } from "react";
import { SafeAreaView, ScrollView, View, Text } from "react-native";

import { getBoards } from "../api/boards";
import BoardList from "../components/BoardList";


export function BoardsScreen() {
  const [boards, setBoards] = useState([]);
  const logBoards = () => {
    console.log(boards);
  };

  const loadData = async () => {
    const boardResult = await getBoards();
    setBoards(boardResult);
  }

  useEffect(() => {
    console.log("BoardsScreen useEffect");
    loadData();
    logBoards();
  }, []);

  return (
    <ScrollView contentContainerStyle={{ paddingHorizontal: 24 }}>
      <SafeAreaView>
        <Text>Boards</Text>
        {boards && <BoardList boards={boards} />}
      </SafeAreaView>
    </ScrollView>
  );
}
