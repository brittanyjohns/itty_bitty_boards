import {
  Text,
  View,
  StyleSheet,
  ImageBackground,
  Pressable,
  ScrollView,
} from "react-native";
import { Stack } from "expo-router";
import { useEffect, useState } from "react";
import { BoardWithImages } from "../../types";
import { useRoute } from "@react-navigation/native";
import { getBoardWithImages } from "../../api/boards";
import { Link, useLocalSearchParams } from "expo-router";
import { Image } from "expo-image";
import * as Speech from "expo-speech";

export default function SingleBoard() {
  const route = useRoute();
  const [wordList, setWordList] = useState([]);
  const [board, setBoard] = useState<BoardWithImages>({
    id: "",
    user_id: "",
    name: "",
    images: [],
  });

  const speak = (thingToSay: string) => {
    Speech.speak(thingToSay);
  };

  useEffect(() => {
    if (!("id" in route.params)) {
      return;
    }
    getBoardWithImages(route.params.id as string).then((board) =>
      setBoard(board)
    );
  }, []);

  const reloadBoardAndImages = () => {
    getBoardWithImages((route.params as { id: string })?.id).then((board) =>
      setBoard(board)
    );
  }

  return (
    <ScrollView contentContainerStyle={{ paddingHorizontal: 12 }}>
      <Stack.Screen options={{ title: board.name }} />
      <View style={styles.boardBox}>
        <Link href="/" asChild>
          <Pressable>
            <Text>Navigate to index.js</Text>
          </Pressable>
        </Link>
        <Text style={styles.textStyleName}>{board.name}</Text>
        <View style={styles.imagesContainer}>
          {board.images.map((image) => (
            <View key={image.id} style={styles.imageWrapper}>
              <Pressable onPress={() => speak(image.label)}>
                <Image
                  source={{
                    uri: `https://picsum.photos/seed/69${image.id}/200/200`,
                  }}
                  style={styles.image}
                />
                <Text style={styles.text}>{image.label}</Text>
              </Pressable>
            </View>
          ))}
        </View>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    padding: 24,
    backgroundColor: "#38434D",
  },
  textStyleName: {
    fontSize: 32,
    fontWeight: "bold",
  },
  boardBox: {
    backgroundColor: "#fff",
    borderRadius: 10,
    padding: 10,
    marginBottom: 10,
  },
  imagesContainer: {
    flexDirection: "row",
    flexWrap: "wrap",
    justifyContent: "flex-start",
    marginBottom: 12,
  },
  imageWrapper: {
    width: "30%", // Adjusted for three columns
    margin: "1%", // Slight margin for spacing
    aspectRatio: 1,
    marginBottom: 12,
    marginTop: 12,
  },
  image: {
    minHeight: 100,
    minWidth: 100,
    height: "85%", // Adjusted to leave space for the label
    // contentFit: "cover",
  },
  text: {
    color: "white",
    fontSize: 18,
    lineHeight: 24,
    fontWeight: "bold",
    textAlign: "center",
    backgroundColor: "#000000c0",
    paddingTop: 2,
  },
});
