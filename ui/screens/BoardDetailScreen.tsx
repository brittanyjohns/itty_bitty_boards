import React, { useState, useEffect } from 'react';
import { View, Text, Image, Pressable, StyleSheet, Dimensions, FlatList, Linking } from 'react-native';
import { getBoardWithImages } from '../api/boards';
import * as Speech from "expo-speech";

export function BoardDetailScreen({ route }) {
    const { id } = route.params;
    const [board, setBoard] = useState(null);
    const [screenWidth] = useState<number>(Dimensions.get('window').width);

    useEffect(() => {
        const loadBoardData = async () => {
            const boardData = await getBoardWithImages(id); // Fetch board data by ID
            setBoard(boardData);
        };

        loadBoardData();
    }, [id]);

    const speak = (thingToSay: string) => {
        Speech.speak(thingToSay);
    };

    useEffect(() => {
        Linking.getInitialURL().then(url => {
          if (url) {
            // Handle the initial URL here
            console.log(`App opened with URL: ${url}`);
            // You can parse the URL and navigate to the appropriate screen
          }
        }).catch(err => console.error('An error occurred', err));
      }, []);

    if (!board) {
        return <Text>Loading...</Text>; // Display loading text or a spinner
    }

    // Calculate the size of the image boxes
    const imageBoxSize: number = screenWidth / NUM_COLUMNS - (2 * IMAGE_MARGIN);

    // Render each image
    const renderImage = ({ item }) => (
        <Pressable
            key={item.id}
            style={[styles.imageWrapper, { width: imageBoxSize, height: imageBoxSize }]}
            onPress={() => speak(item.label)}
        >
            <Image
                source={{ uri: item.url }}
                style={styles.image}
            />
            <Text style={styles.text}>{item.label}</Text>
        </Pressable>
    );

    return (
        <View style={styles.container}>
            <FlatList
                data={board.images}
                renderItem={renderImage}
                keyExtractor={item => item.id.toString()}
                numColumns={NUM_COLUMNS}
            />
        </View>
    );
}

const NUM_COLUMNS = 3; // Number of columns in the grid
const IMAGE_MARGIN = 2; // Margin around each image

const styles = StyleSheet.create({
    container: {
        flex: 1,
        alignItems: "center",
        padding: 24,
        backgroundColor: "#38434D",
    },
    textStyleName: {
        fontSize: 64,
        fontWeight: "bold",
    },
    imageBox: {
        backgroundColor: "#fff",
        borderRadius: 10,
        padding: 10,
        marginBottom: 10,
    },
    // imagesContainer: {
    //     flexDirection: "row",
    //     flexWrap: "wrap",
    //     justifyContent: "flex-start",
    // },
    imageWrapper: {
        margin: IMAGE_MARGIN,
        marginBottom: 5,
    },
    image: {
        minHeight: 100,
        minWidth: 100,
        //   height: "85%", // Adjusted to leave space for the label
        //   contentFit: "cover",
    },
    text: {
        color: "white",
        fontSize: 12,
        lineHeight: 24,
        fontWeight: "bold",
        textAlign: "center",
        backgroundColor: "#000000c0",
        paddingTop: 2,
        marginBottom: 2,
    },
});
