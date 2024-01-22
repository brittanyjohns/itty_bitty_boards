import React, { useEffect, useState } from "react";
import { SafeAreaView, ScrollView, View, Text } from "react-native";
import { useLocalSearchParams } from "expo-router";

import { getImages } from "../api/imageItems";
import ImageList from "../components/ImageList";

export function ImagesScreen() {
  const [images, setImages] = useState([]);
  const { slug } = useLocalSearchParams();
  const logImages = () => {
    console.log(images);
    console.log(slug);
  };
  const gotToImage = () => {
    console.log("Going to image");
  };
  useEffect(() => {
    getImages().then((images) => setImages(images));
    logImages();
  }, []);

  return (
    <ScrollView contentContainerStyle={{ paddingHorizontal: 24 }}>
      <SafeAreaView>
        <Text>Image List</Text>
        <ImageList images={images} />
      </SafeAreaView>
    </ScrollView>
  );
}
